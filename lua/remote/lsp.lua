--- Finding the project root for a remote language server.
---
--- remote-ssh.nvim walks up from the file one `ssh` at a time, looking for a
--- root marker in each directory, and does it through `vim.fn.system()` -- so
--- Neovim is blocked for a round trip per level, and the buffer cannot appear
--- until the walk reaches `/`. Its cache is keyed on the file, but the answer
--- depends only on the directory, so every file in a project pays the walk
--- again.
---
--- This does the climb on the far side instead: one `ssh` for the whole thing,
--- over the connection `remote.ssh` already keeps open. Then it records the
--- answer for every directory between the file and the root, which is where the
--- caching actually pays -- once any file in a project has been opened, the
--- rest are free.
---
--- Only clangd and rust-analyzer reach here at all. Everything else runs under
--- `fast_root_detection`, which skips the search and uses the file's own
--- directory.

local M = {}

--- Climb from $1 until a directory holds one of the remaining arguments.
--- Mirrors what it replaces: at most `depth` directories, and `/` itself is
--- never a candidate.
local WALK = [[
d=$1
depth=$2
shift 2
i=1
while [ "$i" -le "$depth" ]; do
  for p in "$@"; do
    if [ -e "$d/$p" ]; then
      printf '%s\n' "$d"
      exit 0
    fi
  done
  parent=$(dirname "$d")
  if [ "$parent" = "$d" ] || [ "$parent" = "/" ] || [ -z "$parent" ]; then
    break
  fi
  d=$parent
  i=$((i + 1))
done
exit 1
]]

--- dir -> root, per host and marker set. Entries are a string and a timestamp.
---@type table<string, { root: string, at: integer }>
local roots = {}

local function cfg()
  return require("remote-lsp.config").config
end

local function key(host, dir, patterns)
  return host .. "\0" .. dir .. "\0" .. table.concat(patterns, ",")
end

local function cached(k)
  local hit = roots[k]
  if hit and (os.time() - hit.at) < (cfg().root_cache_ttl or 300) then
    return hit.root
  end
end

--- Record `root` for `dir` and every directory above it up to `root` itself.
--- They all resolve to the same place, so the next file in the project -- in
--- any of its subdirectories -- answers from memory.
local function remember(host, dir, patterns, root)
  if cfg().root_cache_enabled == false then
    return
  end
  local at, d = os.time(), dir
  while true do
    roots[key(host, d, patterns)] = { root = root, at = at }
    if d == root or d == "/" then
      return
    end
    local parent = vim.fn.fnamemodify(d, ":h")
    if parent == d then
      return
    end
    d = parent
  end
end

--- Everything cached is a guess about the filesystem on the other side, and it
--- goes stale the moment you generate a `compile_commands.json` that was not
--- there when the walk ran.
function M.forget()
  roots = {}
  pcall(function()
    require("remote-lsp.utils").clear_project_root_cache()
  end)
end

function M.setup()
  local utils = require("remote-lsp.utils")
  local walk_up = utils.find_project_root

  ---@param host string
  ---@param path string remote absolute path of the file
  ---@param root_patterns string[]
  ---@param server_name? string
  ---@return string
  utils.find_project_root = function(host, path, root_patterns, server_name)
    if not root_patterns or #root_patterns == 0 then
      return vim.fn.fnamemodify(path, ":h")
    end
    -- A Cargo workspace root is not "the nearest directory with a marker" -- it
    -- is the nearest `.git` *and* `Cargo.toml` together, a different search.
    if vim.tbl_contains(root_patterns, "Cargo.toml") then
      return walk_up(host, path, root_patterns, server_name)
    end

    local abs = (path:match("^/") and path or "/" .. path):gsub("//+", "/")
    local dir = vim.fn.fnamemodify(abs, ":h")

    if cfg().root_cache_enabled ~= false then
      local hit = cached(key(host, dir, root_patterns))
      if hit then
        return hit
      end
    end

    local args = { dir, tostring(cfg().max_root_search_depth or 10) }
    vim.list_extend(args, root_patterns)
    local argv = require("remote.ssh").cmd(host, WALK, args)
    local done = vim.system(argv, { text = true }):wait(15000)

    local root = done.code == 0 and vim.trim(done.stdout or "") or ""
    -- No marker anywhere above it: the file's own directory, same as before.
    root = root ~= "" and root or dir
    remember(host, dir, root_patterns, root)
    return root
  end

  vim.api.nvim_create_user_command("RemoteRootForget", function()
    M.forget()
    vim.notify("Forgot cached remote project roots")
  end, { desc = "Re-detect remote project roots (after generating compile_commands.json)" })
end

return M
