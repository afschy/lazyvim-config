--- SSH transport shared by the remote snacks pickers.
---
--- remote-ssh.nvim names its buffers `rsync://user@host//abs/path` and does its
--- own browsing through Telescope. We reuse its buffer + LSP layer but produce
--- directory listings here, so the results can be handed to a snacks picker.
---
--- Every command reuses a persistent ssh control socket, so only the first call
--- to a host pays for the handshake and the rest cost about one round trip.
--- That is what keeps browsing responsive enough to feel local.
local M = {}

M.config = {
  scheme = "rsync", -- protocol remote-ssh.nvim uses for buffer names
  ttl = 30, -- seconds a directory listing stays fresh
  timeout = 20000, -- ms before an ssh command is given up on
  control_persist = "10m", -- how long an idle master connection is kept
  prefetch = true, -- pull grandchildren after a listing, so expanding is instant
  prefetch_max = 20000, -- skip the prefetch for directories larger than this
  read_limit = 256 * 1024, -- bytes fetched for a preview
}

---------------------------------------------------------------------------
-- URLs
---------------------------------------------------------------------------

---@class remote.Loc
---@field host string user@host as ssh understands it
---@field path string absolute path on the remote

--- Split `rsync://user@host//abs/path` into host and path.
--- Both the single- and double-slash spellings are accepted, since
--- remote-ssh.nvim tolerates either.
---@param url string
---@return remote.Loc|nil
function M.parse(url)
  if type(url) ~= "string" then
    return nil
  end
  local host, path = url:match("^%w+://([^/]+)//?(.*)$")
  if not host or host == "" then
    return nil
  end
  return { host = host, path = "/" .. (path:gsub("^/+", "")) }
end

---@param url string
---@return boolean
function M.is_remote(url)
  return M.parse(url) ~= nil
end

--- Build the double-slash URL form, which is what the plugin writes into
--- buffer names. Keeping the same spelling everywhere means a buffer opened
--- from a picker is reused rather than duplicated.
---@param host string
---@param path string
---@return string
function M.url(host, path)
  local abs = "/" .. (path:gsub("^/+", ""):gsub("(.)/+$", "%1"))
  return ("%s://%s/%s"):format(M.config.scheme, host, abs)
end

---@param url string
---@return string|nil
function M.dirname(url)
  local loc = M.parse(url)
  if not loc or loc.path == "/" then
    return nil
  end
  local parent = loc.path:match("^(.*)/[^/]+$")
  return M.url(loc.host, (parent == nil or parent == "") and "/" or parent)
end

---@param url string
---@return string
function M.basename(url)
  local loc = M.parse(url)
  if not loc then
    return url
  end
  return loc.path:match("([^/]+)$") or "/"
end

---@param url string directory url
---@param name string entry name, may contain slashes
---@return string
function M.join(url, name)
  local loc = assert(M.parse(url), "not a remote url: " .. tostring(url))
  return M.url(loc.host, (loc.path:gsub("(.)/+$", "%1")) .. "/" .. name)
end

--- Path of `url` as displayed under `root`. Used as the picker's match text.
---@param url string
---@param root string
---@return string
function M.relative(url, root)
  if url == root then
    return ""
  end
  local prefix = (root:gsub("(.)/+$", "%1")) .. "/"
  return url:sub(1, #prefix) == prefix and url:sub(#prefix + 1) or url
end

--- Split the shorthands people actually type into host and path: `user@host`,
--- `user@host:/path`, `user@host//path`, or a full url. The path comes back
--- exactly as typed, so a leading `~` survives for the remote to expand.
---@param input string
---@return string|nil host, string|nil path, string|nil err
function M.split(input)
  input = vim.trim(input or "")
  if input == "" then
    return nil, nil, "empty remote path"
  end
  local loc = M.parse(input)
  if loc then
    return loc.host, loc.path
  end
  local host, path = input:match("^([^/:]+):(.*)$")
  if not host then
    host, path = input:match("^([^/:]+)//(.*)$")
    path = path and ("/" .. path) or nil
  end
  if not host and input:match("^[^/:]+$") then
    host = input
  end
  if not host then
    return nil, nil, "expected user@host:/path, got: " .. input
  end
  return host, (path == nil or path == "") and "~" or path
end

--- Normalise to a url without talking to the remote. Rejects `~`, which only
--- the remote can expand; use `M.resolve` for anything a human typed.
---@param input string
---@return string|nil url, string|nil err
function M.normalize(input)
  local host, path, err = M.split(input)
  if not host then
    return nil, err
  end
  if path:sub(1, 1) ~= "/" then
    return nil, "remote path must be absolute: " .. input
  end
  return M.url(host, path)
end

---------------------------------------------------------------------------
-- Running commands
---------------------------------------------------------------------------

--- POSIX single-quoting. `vim.fn.shellescape` quotes for the *local* shell,
--- but these strings are parsed by the login shell on the remote, which may be
--- fish or anything else. Single quotes mean the same thing in all of them.
---@param s string
---@return string
local function sq(s)
  return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

--- Exposed because anything else building a remote command line needs it too.
M.quote = sq

-- Resolved once, at load: commands are spawned from inside picker finders,
-- which run in a libuv callback where Vimscript functions are off limits.
-- Shared with the file-open path. `~/.ssh/config` points ssh's ControlPath at
-- this same `~/.ssh/sockets/%C`, so browsing warms the master that remote-ssh's
-- bare `ssh`/`scp` then reuse when opening a file. Keep the two in lockstep.
local control_dir = vim.fs.joinpath(vim.fn.expand("~"), ".ssh", "sockets")
vim.uv.fs_mkdir(control_dir, tonumber("700", 8))

local function ctrl_path()
  -- %C hashes host/port/user, so the socket name stays short enough for the
  -- 104-byte sockaddr_un limit even with long hostnames.
  return control_dir .. "/%C"
end

---@param host string
---@param command string
---@return string[]
local function ssh_argv(host, command)
  return {
    "ssh",
    -- No password prompts: vim.system cannot answer one, so failing fast with
    -- a readable error beats hanging until the timeout.
    "-o",
    "BatchMode=yes",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "ServerAliveInterval=15",
    "-o",
    "ServerAliveCountMax=3",
    "-o",
    "ControlMaster=auto",
    "-o",
    "ControlPath=" .. ctrl_path(),
    "-o",
    "ControlPersist=" .. M.config.control_persist,
    host,
    command,
  }
end

--- Full argv for running a POSIX shell snippet on `host`, with `$1`, `$2`, ...
--- bound to `args`. `M.exec` runs it for you; this is for callers that want the
--- process itself, such as the pickers that stream output straight into snacks.
---@param host string
---@param script string
---@param args string[]|nil
---@return string[]
function M.cmd(host, script, args)
  local parts = { "sh", "-c", sq(script), "sh" }
  for _, a in ipairs(args or {}) do
    parts[#parts + 1] = sq(a)
  end
  return ssh_argv(host, table.concat(parts, " "))
end

--- Run a POSIX shell snippet on `host`. `$1`, `$2`, ... are the given args.
---@param host string
---@param script string
---@param args string[]|nil
---@param cb fun(ok: boolean, lines: string[], err: string)
function M.exec(host, script, args, cb)
  vim.system(M.cmd(host, script, args), {
    text = true,
    timeout = M.config.timeout,
  }, function(res)
    local lines = vim.split(res.stdout or "", "\n", { trimempty = true })
    local err = vim.trim(res.stderr or "")
    vim.schedule(function()
      cb(res.code == 0, lines, err ~= "" and err or (res.code ~= 0 and "ssh exited " .. res.code or ""))
    end)
  end)
end

--- Drop any multiplexed connection to `host`, e.g. after the network moved and
--- the old sockets point nowhere. The next command opens a fresh one.
---@param host? string host, or nil for every host
function M.disconnect(host)
  if host then
    vim.system({ "ssh", "-o", "ControlPath=" .. ctrl_path(), "-O", "exit", host }, {}, function() end)
  else
    vim.fn.delete(control_dir, "rf")
    vim.uv.fs_mkdir(control_dir, tonumber("700", 8))
  end
  M.invalidate()
end

-- `cd` is what expands `~` and follows symlinks, and `pwd` reports where we
-- actually landed. Doing it on the far side doubles as the cheapest possible
-- reachability check, so a wrong host or path fails here instead of halfway
-- through building a picker.
local RESOLVE = [[
p=$1
case $p in
  '~') p=$HOME ;;
  '~/'*) p=$HOME/${p#'~/'} ;;
esac
cd -- "$p" 2>/dev/null || { echo "no such directory: $p" >&2; exit 1; }
pwd
]]

--- Canonical url for whatever the user typed, resolved on the remote.
---@param input string
---@param cb fun(url: string|nil, err: string|nil)
function M.resolve(input, cb)
  local host, path, err = M.split(input)
  if not host then
    return cb(nil, err)
  end
  M.exec(host, RESOLVE, { path }, function(ok, lines, e)
    if not ok or not lines[1] then
      return cb(nil, e ~= "" and e or ("cannot open " .. host .. ":" .. path))
    end
    cb(M.url(host, lines[1]))
  end)
end

---------------------------------------------------------------------------
-- Listing cache
---------------------------------------------------------------------------

---@class remote.Entry
---@field name string
---@field dir boolean

---@type table<string, {entries: remote.Entry[], at: integer}>
local cache = {}

---@param a remote.Entry
---@param b remote.Entry
local function by_kind_then_name(a, b)
  if a.dir ~= b.dir then
    return a.dir
  end
  local la, lb = a.name:lower(), b.name:lower()
  if la ~= lb then
    return la < lb
  end
  return a.name < b.name
end

---@param lines string[] `d name` / `f name`, one per entry
---@return remote.Entry[]
local function parse_entries(lines)
  local entries = {}
  for _, line in ipairs(lines) do
    local kind, name = line:match("^([df]) (.+)$")
    if name then
      entries[#entries + 1] = { name = name, dir = kind == "d" }
    end
  end
  table.sort(entries, by_kind_then_name)
  return entries
end

---@param url string
---@param entries remote.Entry[]
local function cache_set(url, entries)
  cache[url] = { entries = entries, at = vim.uv.now() }
end

--- Cached listing for `url`, or nil when it is missing or stale.
--- Deliberately synchronous: the picker finder calls this to render whatever is
--- already known, and only falls back to `M.ls` for what is not.
---@param url string
---@return remote.Entry[]|nil
function M.cached(url)
  local hit = cache[url]
  if not hit then
    return nil
  end
  if (vim.uv.now() - hit.at) > (M.config.ttl * 1000) then
    return nil
  end
  return hit.entries
end

--- Forget the listing for `url` and everything below it.
---@param url string|nil nil clears the whole cache
function M.invalidate(url)
  if not url then
    cache = {}
    return
  end
  local prefix = (url:gsub("(.)/+$", "%1")) .. "/"
  for key in pairs(cache) do
    if key == url or key:sub(1, #prefix) == prefix then
      cache[key] = nil
    end
  end
end

-- Portable listing: `find -printf` is GNU-only, and `ls -F` mangles odd names,
-- so test each entry with `[ -d ]`. That follows symlinks, which is what we
-- want -- a link to a directory should open like one.
local LIST = [[
cd -- "$1" 2>/dev/null || { echo "cannot read directory" >&2; exit 1; }
find . -mindepth 1 -maxdepth 1 2>/dev/null | while IFS= read -r f; do
  if [ -d "$f" ]; then printf 'd %s\n' "${f#./}"; else printf 'f %s\n' "${f#./}"; fi
done
]]

-- One extra round trip fills in every grandchild, so expanding a directory the
-- user can already see is instant. Counting first keeps a huge tree from
-- dragging megabytes over the wire for a listing nobody asked for.
local PREFETCH = [[
cd -- "$1" 2>/dev/null || exit 0
[ "$(find . -mindepth 2 -maxdepth 2 2>/dev/null | wc -l)" -gt "$2" ] && exit 0
find . -mindepth 2 -maxdepth 2 2>/dev/null | while IFS= read -r f; do
  if [ -d "$f" ]; then printf 'd %s\n' "${f#./}"; else printf 'f %s\n' "${f#./}"; fi
done
]]

---@param url string directory whose children were just listed
---@param children remote.Entry[] that listing, so empty subdirectories are cached too
local function prefetch(url, children)
  local loc = M.parse(url)
  if not loc then
    return
  end
  M.exec(loc.host, PREFETCH, { loc.path, tostring(M.config.prefetch_max) }, function(ok, lines)
    if not ok then
      return
    end
    ---@type table<string, remote.Entry[]>
    local buckets = {}
    for _, child in ipairs(children) do
      if child.dir then
        buckets[child.name] = {}
      end
    end
    for _, line in ipairs(lines) do
      local kind, rel = line:match("^([df]) (.+)$")
      local parent, name ---@type string?, string?
      if rel then
        parent, name = rel:match("^([^/]+)/(.+)$")
      end
      -- Only trust names we saw at depth 1; anything else means the tree
      -- changed under us and the grandchild listing is not ours to cache.
      if name and buckets[parent] then
        table.insert(buckets[parent], { name = name, dir = kind == "d" })
      end
    end
    for name, entries in pairs(buckets) do
      table.sort(entries, by_kind_then_name)
      local child_url = M.join(url, name)
      -- Never clobber a fresher listing fetched directly.
      if not M.cached(child_url) then
        cache_set(child_url, entries)
      end
    end
  end)
end

--- List a remote directory, filling the cache.
---@param url string
---@param cb fun(ok: boolean, entries: remote.Entry[], err: string)
function M.ls(url, cb)
  local loc = M.parse(url)
  if not loc then
    return cb(false, {}, "not a remote url: " .. tostring(url))
  end
  M.exec(loc.host, LIST, { loc.path }, function(ok, lines, err)
    if not ok then
      return cb(false, {}, err)
    end
    local entries = parse_entries(lines)
    cache_set(url, entries)
    if M.config.prefetch then
      prefetch(url, entries)
    end
    cb(true, entries, "")
  end)
end

---------------------------------------------------------------------------
-- Whole-tree queries
---------------------------------------------------------------------------

-- fd and ripgrep both honour .gitignore and are enormously faster than find on
-- a big checkout, so prefer them when the remote has one. The marker line tells
-- us which ran, since their output differs.
local FIND_FILES = [[
cd -- "$1" 2>/dev/null || { echo "__err__ cannot read directory: $1"; exit 1; }
if command -v fd >/dev/null 2>&1; then
  echo "__tool__ fd"; fd --type f --hidden --exclude .git --strip-cwd-prefix
elif command -v fdfind >/dev/null 2>&1; then
  echo "__tool__ fd"; fdfind --type f --hidden --exclude .git --strip-cwd-prefix
elif command -v rg >/dev/null 2>&1; then
  echo "__tool__ rg"; rg --files --hidden --glob '!.git'
else
  echo "__tool__ find"; find . -type f -not -path '*/.git/*' 2>/dev/null | sed 's|^\./||'
fi
]]

--- Every file under `url`, as urls.
---@param url string
---@param cb fun(ok: boolean, files: string[], err: string, tool: string)
function M.find_files(url, cb)
  local loc = M.parse(url)
  if not loc then
    return cb(false, {}, "not a remote url: " .. tostring(url), "")
  end
  M.exec(loc.host, FIND_FILES, { loc.path }, function(ok, lines, err)
    local tool = ""
    local files = {}
    for _, line in ipairs(lines) do
      local t, e = line:match("^__tool__ (%S+)$"), line:match("^__err__ (.+)$")
      if e then
        return cb(false, {}, e, "")
      elseif t then
        tool = t
      elseif line ~= "" then
        files[#files + 1] = M.join(url, (line:gsub("^%./", "")))
      end
    end
    if not ok then
      return cb(false, {}, err, "")
    end
    cb(true, files, "", tool)
  end)
end

local GREP = [[
cd -- "$1" 2>/dev/null || { echo "__err__ cannot read directory: $1"; exit 1; }
if command -v rg >/dev/null 2>&1; then
  echo "__tool__ rg"
  rg --vimgrep --smart-case --hidden --glob '!.git' --max-columns 500 -e "$2"
else
  echo "__tool__ grep"
  grep -rnI --exclude-dir=.git -e "$2" . 2>/dev/null | sed 's|^\./||'
fi
]]

---@class remote.Match
---@field file string url
---@field line integer
---@field col integer
---@field text string

--- Search `url` for `pattern`.
---@param url string
---@param pattern string
---@param cb fun(ok: boolean, matches: remote.Match[], err: string)
function M.grep(url, pattern, cb)
  local loc = M.parse(url)
  if not loc then
    return cb(false, {}, "not a remote url: " .. tostring(url))
  end
  M.exec(loc.host, GREP, { loc.path, pattern }, function(ok, lines, err)
    -- rg and grep both exit 1 on "no matches", which is not a failure. A real
    -- problem is reported on stdout instead, and handled in the loop below.
    if not ok and err ~= "" and not err:match("^ssh exited 1$") then
      return cb(false, {}, err)
    end
    local matches = {}
    local tool = "grep"
    for _, line in ipairs(lines) do
      local t, e = line:match("^__tool__ (%S+)$"), line:match("^__err__ (.+)$")
      if e then
        return cb(false, {}, e)
      elseif t then
        tool = t
      elseif tool == "rg" then
        local file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
        if file then
          matches[#matches + 1] = { file = M.join(url, file), line = tonumber(lnum), col = tonumber(col), text = text }
        end
      else
        local file, lnum, text = line:match("^(.-):(%d+):(.*)$")
        if file then
          matches[#matches + 1] = { file = M.join(url, file), line = tonumber(lnum), col = 1, text = text }
        end
      end
    end
    cb(true, matches, "")
  end)
end

--- The shell snippets behind the whole-tree queries, so the streaming pickers
--- can run exactly the same code as the callback API above.
M.scripts = { find_files = FIND_FILES, grep = GREP }

--- Head of a remote file, for previews.
---@param url string
---@param cb fun(ok: boolean, lines: string[], err: string)
function M.read(url, cb)
  local loc = M.parse(url)
  if not loc then
    return cb(false, {}, "not a remote url: " .. tostring(url))
  end
  M.exec(loc.host, 'head -c "$2" -- "$1"', { loc.path, tostring(M.config.read_limit) }, cb)
end

---------------------------------------------------------------------------
-- Mutations
---------------------------------------------------------------------------

---@param url string
---@param script string
---@param args string[]
---@param cb fun(ok: boolean, err: string)
local function mutate(url, script, args, cb)
  local loc = M.parse(url)
  if not loc then
    return cb(false, "not a remote url: " .. tostring(url))
  end
  M.exec(loc.host, script, args, function(ok, _, err)
    if ok then
      M.invalidate(M.dirname(url) or url)
      M.invalidate(url)
    end
    cb(ok, err)
  end)
end

---@param url string
---@param cb fun(ok: boolean, err: string)
function M.mkdir(url, cb)
  mutate(url, 'mkdir -p -- "$1"', { assert(M.parse(url)).path }, cb)
end

---@param url string
---@param cb fun(ok: boolean, err: string)
function M.touch(url, cb)
  mutate(url, 'mkdir -p -- "$(dirname -- "$1")" && touch -- "$1"', { assert(M.parse(url)).path }, cb)
end

---@param url string
---@param cb fun(ok: boolean, err: string)
function M.remove(url, cb)
  mutate(url, 'rm -rf -- "$1"', { assert(M.parse(url)).path }, cb)
end

---@param from string
---@param to string
---@param cb fun(ok: boolean, err: string)
function M.copy(from, to, cb)
  local a, b = M.parse(from), M.parse(to)
  if not a or not b then
    return cb(false, "not a remote url")
  end
  if a.host ~= b.host then
    return cb(false, "cannot copy across hosts")
  end
  mutate(to, 'mkdir -p -- "$(dirname -- "$2")" && cp -R -- "$1" "$2"', { a.path, b.path }, cb)
end

---@param from string
---@param to string
---@param cb fun(ok: boolean, err: string)
function M.rename(from, to, cb)
  local a, b = M.parse(from), M.parse(to)
  if not a or not b then
    return cb(false, "not a remote url")
  end
  if a.host ~= b.host then
    return cb(false, "cannot rename across hosts")
  end
  mutate(from, 'mkdir -p -- "$(dirname -- "$2")" && mv -- "$1" "$2"', { a.path, b.path }, function(ok, err)
    M.invalidate(M.dirname(to) or to)
    cb(ok, err)
  end)
end

return M
