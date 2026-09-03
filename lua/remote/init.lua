--- Remote development over ssh, driven from snacks.
---
--- remote-ssh.nvim owns the buffers: it fetches a file into an `acwrite`
--- buffer named `rsync://user@host//path`, rsyncs it back on `:w`, and runs the
--- language server on the far side. What it does not have is a file browser
--- that behaves like the one used for local work, so everything under
--- `remote/` supplies that half: snacks picker sources that read the remote
--- filesystem over ssh and hand any file that gets opened back to the plugin.

local Explorer = require("remote.explorer")
local Open = require("remote.open")
local Pickers = require("remote.pickers")
local ssh = require("remote.ssh")

local M = {}

--- Directory the remote pickers are currently working in, shared by all of
--- them so the explorer, the file finder and the grep stay on the same tree.
M.root = nil ---@type string|nil

M.open = Open.open
M.disconnect = ssh.disconnect

--- Every source registered under `opts.picker.sources`.
M.sources = vim.tbl_extend("error", { remote_explorer = Explorer.source }, Pickers.sources)

---------------------------------------------------------------------------
-- Picking a root
---------------------------------------------------------------------------

--- Hosts from the ssh config, so "connect to a machine" needs no typing. One
--- level of `Include` is followed, since splitting the config up is common.
---@return string[]
function M.hosts()
  local files, hosts, seen = { vim.fn.expand("~/.ssh/config") }, {}, {}
  local i = 1
  while i <= #files do
    local file = files[i]
    i = i + 1
    if vim.fn.filereadable(file) == 1 then
      for _, line in ipairs(vim.fn.readfile(file)) do
        local include = line:match("^%s*[Ii]nclude%s+(.+)%s*$")
        local names = line:match("^%s*[Hh]ost%s+(.+)%s*$")
        if include and i <= 2 then
          vim.list_extend(files, vim.fn.glob(vim.fn.expand(include), false, true))
        elseif names then
          for name in names:gmatch("%S+") do
            if not name:find("[*?]") and not seen[name] then
              seen[name] = true
              hosts[#hosts + 1] = name
            end
          end
        end
      end
    end
  end
  return hosts
end

--- Recently opened remote directories, most recent first. History entries point
--- at files as often as directories, so a file entry contributes its parent.
---@return {url: string, pinned: boolean}[]
local function recent()
  local ok, history = pcall(require, "async-remote-write.session_picker")
  if not ok then
    return {}
  end
  local out, seen = {}, {}
  for _, group in ipairs({ { history.get_pinned(), true }, { history.get_history(), false } }) do
    for _, entry in ipairs(group[1] or {}) do
      local url = entry.url and ssh.is_remote(entry.url) and entry.url or nil
      if url and entry.type ~= "tree_browser" then
        url = ssh.dirname(url) or url
      end
      if url and not seen[url] then
        seen[url] = true
        out[#out + 1] = { url = url, pinned = group[2] }
      end
    end
  end
  return out
end

--- Ask for a remote path by hand, and check it exists before handing it on.
---@param cb fun(url: string)
---@param default? string
function M.prompt_root(cb, default)
  Snacks.input({ prompt = "Remote root (user@host:/path)", default = default }, function(value)
    if not value or vim.trim(value) == "" then
      return
    end
    ssh.resolve(value, function(url, err)
      if not url then
        return Snacks.notify.error("Cannot open `" .. value .. "`:\n" .. tostring(err))
      end
      cb(url)
    end)
  end)
end

--- Where do you want to work? Recent directories first, then every host the ssh
--- config knows about (which lands you in its home directory), then free text.
---@param cb fun(url: string)
function M.pick_root(cb)
  local items = {} ---@type snacks.picker.finder.Item[]

  for _, entry in ipairs(recent()) do
    local loc = ssh.parse(entry.url)
    items[#items + 1] = {
      url = entry.url,
      icon = entry.pinned and " " or " ",
      label = loc.path,
      comment = loc.host,
      text = entry.url,
    }
  end

  local seen = {}
  for _, item in ipairs(items) do
    seen[ssh.parse(item.url).host] = true
  end
  for _, host in ipairs(M.hosts()) do
    if not seen[host] then
      items[#items + 1] = { host = host, icon = "󰒋 ", label = host, comment = "home directory", text = host }
    end
  end

  items[#items + 1] = { prompt = true, icon = " ", label = "Enter a remote path…", text = "" }

  Snacks.picker.pick({
    source = "remote_roots",
    title = "Remote Root",
    finder = function()
      return items
    end,
    format = function(item)
      return {
        { item.icon, "SnacksPickerIcon" },
        { item.label, item.prompt and "SnacksPickerSpecial" or "SnacksPickerFile" },
        { " " },
        { item.comment or "", "SnacksPickerComment" },
      }
    end,
    preview = "none",
    layout = { preset = "select" },
    confirm = function(picker, item)
      picker:close()
      if not item then
        return
      elseif item.prompt then
        return M.prompt_root(cb)
      elseif item.host then
        -- No path yet: resolve `~` on the far side and start there.
        return ssh.resolve(item.host .. ":~", function(url, err)
          if not url then
            return Snacks.notify.error("Cannot reach `" .. item.host .. "`:\n" .. tostring(err))
          end
          cb(url)
        end)
      end
      cb(item.url)
    end,
  })
end

---------------------------------------------------------------------------
-- Entry points
---------------------------------------------------------------------------

--- Run `fn` with a root, asking for one if this is the first remote thing to
--- happen this session.
---@param opts? table
---@param fn fun(opts: table)
local function with_root(opts, fn)
  opts = opts or {}
  opts.remote_root = opts.remote_root or M.root
  if opts.remote_root then
    M.root = opts.remote_root
    return fn(opts)
  end
  M.pick_root(function(url)
    M.root = url
    opts.remote_root = url
    fn(opts)
  end)
end

--- Open the explorer, or -- when the caller has somewhere specific in mind --
--- move the one that is already open. `pick` on its own toggles, which is right
--- for `<leader>Re` pressed twice and wrong for "connect to this host".
---@param opts? table
function M.explorer(opts)
  local go = opts and (opts.retarget or opts.reveal) ~= nil
  with_root(opts, function(o)
    local reveal, root = o.reveal, o.remote_root
    o.reveal, o.retarget = nil, nil
    local open = Snacks.picker.get({ source = "remote_explorer" })[1]
    if go and open and not open.closed then
      Explorer.set_root(open, root, reveal)
      return open:focus()
    end
    local picker = Snacks.picker.pick("remote_explorer", o)
    if picker and reveal then
      Explorer.reveal(picker, reveal)
    end
  end)
end

---@param opts? table
function M.files(opts)
  with_root(opts, function(o)
    Snacks.picker.pick("remote_files", o)
  end)
end

---@param opts? table
function M.grep(opts)
  with_root(opts, function(o)
    Snacks.picker.pick("remote_grep", o)
  end)
end

---@param opts? table
function M.buffers(opts)
  Snacks.picker.pick("remote_buffers", opts)
end

--- Switch the whole set of pickers to another machine or directory.
function M.connect()
  M.pick_root(function(url)
    M.root = url
    Open.track(url, "tree")
    M.explorer({ remote_root = url, retarget = true })
  end)
end

--- A login shell on the machine we are working on, in the directory we are
--- working in.
function M.terminal()
  with_root(nil, function(o)
    local loc = ssh.parse(o.remote_root)
    Snacks.terminal({ "ssh", "-t", loc.host, "cd " .. ssh.quote(loc.path) .. " && exec $SHELL -l" }, {
      win = { position = "bottom" },
    })
  end)
end

return M
