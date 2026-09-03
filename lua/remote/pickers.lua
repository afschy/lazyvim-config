--- The flat remote pickers: fuzzy file finder, live grep, and open remote
--- buffers.
---
--- Files and grep hand the ssh process straight to snacks' own proc finder, so
--- results stream in as they arrive and the next keystroke kills the previous
--- search. Over a network link that streaming is the difference between a live
--- grep and a stopwatch.

local Open = require("remote.open")
local Preview = require("remote.preview")
local ssh = require("remote.ssh")

local M = {}

---@param opts snacks.picker.Config
---@return string|nil
local function root_of(opts)
  return opts.remote_root or require("remote").root
end

---@param url string
---@return string
local function title_of(url)
  local loc = ssh.parse(url)
  return loc and (loc.host .. ":" .. loc.path) or url
end

--- Run a remote script and feed its stdout to the picker one line at a time.
---@param host string
---@param script string
---@param args string[]
---@param ctx snacks.picker.finder.ctx
---@param transform fun(item: snacks.picker.finder.Item): snacks.picker.finder.Item|false
local function stream(host, script, args, ctx, transform)
  local argv = ssh.cmd(host, script, args)
  return require("snacks.picker.source.proc").proc({
    cmd = argv[1],
    args = vim.list_slice(argv, 2),
    -- `rg` and `grep` exit 1 when nothing matched, which is not a failure. Real
    -- problems come back as an `__err__` line instead.
    notify = false,
    transform = transform,
  }, ctx)
end

---@param msg string
local function fail(msg)
  vim.schedule(function()
    Snacks.notify.error(msg)
  end)
end

---------------------------------------------------------------------------
-- Format
---------------------------------------------------------------------------

--- Hand-written because snacks' file formatter runs the path through
--- `vim.fs.normalize`, which collapses the `//` that separates host from path
--- in a remote url.
---@param item snacks.picker.Item
---@param picker snacks.Picker
function M.format(item, picker)
  local ret = {} ---@type snacks.picker.Highlight[]
  local a = Snacks.picker.util.align

  if item.flags then
    ret[#ret + 1] = { a(tostring(item.buf), 3), "SnacksPickerBufNr" }
    ret[#ret + 1] = { " " }
    ret[#ret + 1] = { a(item.flags, 2, { align = "right" }), "SnacksPickerBufFlags" }
    ret[#ret + 1] = { " " }
  end

  local icon, hl = Snacks.util.icon(ssh.basename(item.file), item.dir and "directory" or "file", {
    fallback = picker.opts.icons.files,
  })
  ret[#ret + 1] = { a(icon, picker.opts.formatters.file.icon_width or 2), hl, virtual = true }

  local rel = item.rel or item.file
  local dir, base = rel:match("^(.*/)([^/]+)$")
  if dir then
    ret[#ret + 1] = { dir, "SnacksPickerDir", field = "file" }
  end
  ret[#ret + 1] = { base or rel, "SnacksPickerFile", field = "file" }

  if item.pos and item.line then
    ret[#ret + 1] = { ":", "SnacksPickerDelim" }
    ret[#ret + 1] = { tostring(item.pos[1]), "SnacksPickerRow" }
  end
  ret[#ret + 1] = { " " }

  if item.host then
    ret[#ret + 1] = { item.host, "SnacksPickerComment" }
    ret[#ret + 1] = { " " }
  end
  if item.line then
    Snacks.picker.highlight.format(item, item.line, ret)
  end
  return ret
end

---------------------------------------------------------------------------
-- Finders
---------------------------------------------------------------------------

---@type snacks.picker.finder
function M.files(opts, ctx)
  local root = root_of(opts)
  local loc = root and ssh.parse(root)
  if not loc then
    return {}
  end
  ctx.picker.title = title_of(root)

  return stream(loc.host, ssh.scripts.find_files, { loc.path }, ctx, function(item)
    local line = item.text
    local err = line:match("^__err__ (.+)$")
    if err then
      fail(err)
      return false
    end
    if line:find("^__tool__ ") then
      return false
    end
    local rel = (line:gsub("^%./", ""))
    if rel == "" then
      return false
    end
    item.file = ssh.join(root, rel)
    item._path = item.file
    item.rel = rel
    item.text = rel
    return item
  end)
end

---@type snacks.picker.finder
function M.grep(opts, ctx)
  local root = root_of(opts)
  local loc = root and ssh.parse(root)
  local pattern = vim.trim(ctx.filter.search)
  if not loc or pattern == "" then
    return {}
  end
  ctx.picker.title = title_of(root)

  -- The remote picks the best tool it has; the marker line tells us which, and
  -- therefore whether we get a column.
  local tool = "grep"

  return stream(loc.host, ssh.scripts.grep, { loc.path, pattern }, ctx, function(item)
    local line = item.text
    local err = line:match("^__err__ (.+)$")
    if err then
      fail(err)
      return false
    end
    local t = line:match("^__tool__ (%S+)$")
    if t then
      tool = t
      return false
    end

    local file, lnum, col, text
    if tool == "rg" then
      file, lnum, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
    else
      file, lnum, text = line:match("^(.-):(%d+):(.*)$")
      col = "1"
    end
    if not file then
      return false
    end

    local rel = (file:gsub("^%./", ""))
    item.file = ssh.join(root, rel)
    item._path = item.file
    item.rel = rel
    item.line = text
    item.pos = { tonumber(lnum), math.max(tonumber(col) - 1, 0) }
    item.text = rel .. ":" .. lnum .. ":" .. text
    return item
  end)
end

---@type snacks.picker.finder
function M.buffers(opts, ctx)
  local items = {} ---@type snacks.picker.finder.Item[]
  local current, alternate = vim.api.nvim_get_current_buf(), vim.fn.bufnr("#")

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) or ""
    local loc = ssh.parse(name)
    if loc and (opts.hidden or vim.bo[buf].buflisted) then
      local info = vim.fn.getbufinfo(buf)[1]
      local mark = vim.api.nvim_buf_get_mark(buf, '"')
      items[#items + 1] = {
        buf = buf,
        file = name,
        _path = name,
        host = loc.host,
        rel = loc.path,
        flags = table.concat({
          buf == current and "%" or (buf == alternate and "#" or ""),
          info.hidden == 1 and "h" or (#(info.windows or {}) > 0) and "a" or "",
          vim.bo[buf].modified and "+" or "",
        }),
        info = info,
        pos = mark[1] ~= 0 and mark or { info.lnum, 0 },
        text = loc.host .. ":" .. loc.path,
      }
    end
  end

  table.sort(items, function(a, b)
    return a.info.lastused > b.info.lastused
  end)
  return ctx.filter:filter(items)
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

---@type table<string, snacks.picker.Action.spec>
M.actions = {}

function M.actions.confirm(picker, item)
  if not item or not item.file then
    return
  end
  local win, pos, url = picker.main, item.pos, item.file
  picker:close()
  vim.schedule(function()
    Open.open(url, pos, win)
  end)
end

--- Drop a remote buffer. The rsync writer keeps no state of its own for a
--- buffer that is gone, so this is just `bdelete`.
function M.actions.bufdelete(picker)
  for _, item in ipairs(picker:selected({ fallback = true })) do
    if item.buf then
      Snacks.bufdelete({ buf = item.buf, force = false })
    end
  end
  picker.list:set_selected()
  picker:find()
end

--- Send the current search over to the other remote picker, keeping the root.
function M.actions.remote_grep(picker)
  local root = root_of(picker.opts)
  picker:close()
  require("remote").grep({ remote_root = root })
end

function M.actions.remote_files(picker)
  local root = root_of(picker.opts)
  picker:close()
  require("remote").files({ remote_root = root })
end

function M.actions.remote_explorer(picker)
  local item = picker:current()
  local root = root_of(picker.opts)
  picker:close()
  require("remote").explorer({ remote_root = root, reveal = item and item.file or nil })
end

---------------------------------------------------------------------------
-- Sources
---------------------------------------------------------------------------

local common = {
  format = M.format,
  preview = Preview.preview,
  actions = M.actions,
  show_empty = true,
  win = {
    input = {
      keys = {
        ["<c-e>"] = { "remote_explorer", mode = { "i", "n" } },
      },
    },
  },
}

M.sources = {
  remote_files = vim.tbl_deep_extend("force", common, {
    finder = M.files,
    supports_live = true,
    win = { input = { keys = { ["<c-g>"] = { "remote_grep", mode = { "i", "n" } } } } },
  }),
  remote_grep = vim.tbl_deep_extend("force", common, {
    finder = M.grep,
    live = true,
    supports_live = true,
    regex = true,
    win = { input = { keys = { ["<c-f>"] = { "remote_files", mode = { "i", "n" } } } } },
  }),
  remote_buffers = vim.tbl_deep_extend("force", common, {
    finder = M.buffers,
    hidden = false,
    win = {
      input = { keys = { ["<c-x>"] = { "bufdelete", mode = { "i", "n" } } } },
      list = { keys = { ["dd"] = "bufdelete" } },
    },
  }),
}

return M
