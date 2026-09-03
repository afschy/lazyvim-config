--- `remote_explorer`: the snacks file explorer, backed by ssh.
---
--- The finder only renders what `remote.ssh` already has cached, so it never
--- blocks on the network. Whatever is missing is fetched in the background and
--- the picker re-runs its finder when the listing lands. Together with the
--- depth-2 prefetch in the transport that means the first directory costs one
--- round trip and everything you can already see costs nothing, which is what
--- makes expanding the tree feel local.

local Open = require("remote.open")
local Preview = require("remote.preview")
local ssh = require("remote.ssh")

local M = {}

--- How long a whole-tree file index is reused for the search view. Much longer
--- than a directory listing's TTL because it is a far more expensive query, and
--- `u` forces a refresh anyway. A failed index is kept for `index_retry`
--- instead: long enough not to retry on every keystroke, short enough that a
--- connection which just came back is picked up.
M.index_ttl = 120
M.index_retry = 5

--- Tree state is module-level, not per-picker: closing the explorer and opening
--- it again should land you exactly where you left off.
local expanded = {} ---@type table<string, boolean>
local loading = {} ---@type table<string, boolean>
local failed = {} ---@type table<string, string>
local index = {} ---@type table<string, {files: string[], at: integer, ttl: integer}>
local indexing = {} ---@type table<string, boolean>

---@class remote.explorer.Item: snacks.picker.finder.Item
---@field file string url
---@field dir? boolean
---@field open? boolean
---@field parent? remote.explorer.Item
---@field last? boolean
---@field sort string

---------------------------------------------------------------------------
-- Tree state
---------------------------------------------------------------------------

---@param picker snacks.Picker
---@return string
local function root_of(picker)
  return picker.opts.remote_root or require("remote").root
end

---@param url string
---@return string
local function title_of(url)
  local loc = ssh.parse(url)
  return loc and (loc.host .. ":" .. loc.path) or url
end

--- Path as shown to the user: relative to the root, or just the name when the
--- url *is* the root.
---@param url string
---@param root string
---@return string
local function display(url, root)
  local rel = ssh.relative(url, root)
  return rel ~= "" and rel or ssh.basename(url)
end

--- Directory the next action should act in: the item under the cursor if it is
--- one, otherwise the directory holding it.
---@param picker snacks.Picker
---@return string
local function dir_of(picker)
  local item = picker:current()
  if not item or not item.file then
    return root_of(picker)
  end
  return item.dir and item.file or ssh.dirname(item.file) or root_of(picker)
end

---@type table<snacks.Picker, fun()>
local redraw = setmetatable({}, { __mode = "k" })

--- Entry the cursor should land on once it exists. A reveal usually outlives
--- the redraw that asked for it, because the directories on the way to the
--- target are still being listed, so it is retried after every redraw until it
--- lands.
---@type table<snacks.Picker, string>
local pending = setmetatable({}, { __mode = "k" })

---@param picker snacks.Picker
---@param url string
---@return boolean found
local function reveal(picker, url)
  for item, idx in picker:iter() do
    if item.file == url then
      picker.list:view(idx)
      return true
    end
  end
  return false
end

---@param picker snacks.Picker
local function refind(picker)
  picker.list:set_target()
  picker:find({
    on_done = function()
      local target = pending[picker]
      if target and reveal(picker, target) then
        pending[picker] = nil
      end
    end,
  })
end

--- Redraw once pending listings land. A prefetch answers for a whole level at
--- once, so coalesce the arrivals into a single pass.
---@param picker snacks.Picker
local function schedule(picker)
  if not redraw[picker] then
    local ref = picker:ref()
    redraw[picker] = Snacks.util.debounce(function()
      local p = ref.value
      if p and not p.closed then
        refind(p)
      end
    end, { ms = 30 })
  end
  redraw[picker]()
end

--- Ask for a listing we do not have. Failures are remembered so a directory we
--- cannot read does not turn into a request loop.
---@param picker snacks.Picker
---@param url string
local function request(picker, url)
  if loading[url] or failed[url] then
    return
  end
  loading[url] = true
  ssh.ls(url, function(ok, _, err)
    loading[url] = nil
    if not ok then
      failed[url] = err ~= "" and err or "could not list directory"
    end
    schedule(picker)
  end)
end

--- Open every directory between `root` and `url`, so that revealing `url` has
--- something to reveal.
---@param root string
---@param url string
local function expand_to(root, url)
  local dir = ssh.dirname(url)
  while dir and dir ~= root and #dir > #root do
    expanded[dir] = true
    dir = ssh.dirname(dir)
  end
end

--- Redraw, optionally putting the cursor on `target`. Leaving the search view
--- first is what makes `<CR>` on a search result reveal it in the tree.
---@param picker snacks.Picker
---@param opts? {target?: string}
local function update(picker, opts)
  opts = opts or {}
  if picker.closed then
    return
  end
  if opts.target then
    expand_to(root_of(picker), opts.target)
  end
  pending[picker] = opts.target
  if picker.input.filter.meta.searching then
    picker.input:set("", "")
    picker.list.win:focus()
  end
  refind(picker)
end

--- Point an explorer at another directory, on this host or any other.
---@param picker snacks.Picker
---@param url string
---@param target? string entry to put the cursor on once the new tree is drawn
function M.set_root(picker, url, target)
  picker.opts.remote_root = url
  require("remote").root = url
  expanded[url] = true
  picker.title = title_of(url)
  update(picker, { target = target })
end

--- Bring `url` into view, opening whatever directories it lives under.
---@param picker snacks.Picker
---@param url string
function M.reveal(picker, url)
  update(picker, { target = url })
end

---------------------------------------------------------------------------
-- Finder
---------------------------------------------------------------------------

--- The tree view: root plus every expanded directory below it.
---@param picker snacks.Picker
---@param root string
---@param opts snacks.picker.Config
local function tree_finder(picker, root, opts)
  return function(cb)
    ---@type remote.explorer.Item
    local root_item = { file = root, _path = root, dir = true, open = true, text = "", sort = "" }
    cb(root_item)

    ---@param url string
    ---@param parent remote.explorer.Item
    local function walk(url, parent)
      local entries = ssh.cached(url)
      if not entries then
        request(picker, url)
        -- No `file`, so the formatter renders just the tree branch and this
        -- note, and every action skips it.
        cb({
          parent = parent,
          last = true,
          text = "",
          sort = parent.sort .. " ",
          comment = failed[url] or "loading…",
        })
        return
      end

      local visible = {} ---@type remote.Entry[]
      for _, e in ipairs(entries) do
        if opts.hidden or e.name:sub(1, 1) ~= "." then
          visible[#visible + 1] = e
        end
      end

      for i, e in ipairs(visible) do
        local child = ssh.join(url, e.name)
        ---@type remote.explorer.Item
        local item = {
          file = child,
          -- Pre-seeding `_path` keeps `Snacks.picker.util.path` from running the
          -- url through path normalisation, which would eat the `//`.
          _path = child,
          dir = e.dir,
          open = e.dir and expanded[child] or nil,
          parent = parent,
          last = i == #visible,
          hidden = e.name:sub(1, 1) == ".",
          text = ssh.relative(child, root),
          sort = parent.sort .. (e.dir and "!" or "#") .. e.name .. " ",
        }
        cb(item)
        if item.open then
          walk(child, item)
        end
      end
    end

    walk(root, root_item)
  end
end

--- The search view: every file under the root, rebuilt as a tree so a match
--- still shows the directories it lives in. Same shape as the local explorer.
---@param picker snacks.Picker
---@param root string
---@param opts snacks.picker.Config
local function search_finder(picker, root, opts)
  local hit = index[root]
  local files = hit and (vim.uv.now() - hit.at) < (hit.ttl * 1000) and hit.files or nil

  if not files and not indexing[root] then
    indexing[root] = true
    local ref = picker:ref()
    ssh.find_files(root, function(ok, found, err)
      indexing[root] = nil
      if ok then
        table.sort(found)
        index[root] = { files = found, at = vim.uv.now(), ttl = M.index_ttl }
      else
        Snacks.notify.error("Could not index `" .. title_of(root) .. "`:\n" .. err)
        index[root] = { files = {}, at = vim.uv.now(), ttl = M.index_retry }
      end
      local p = ref.value
      if p and not p.closed then
        refind(p)
      end
    end)
  end

  return function(cb)
    ---@type remote.explorer.Item
    local root_item = { file = root, _path = root, dir = true, open = true, text = "", sort = "" }
    cb(root_item)

    if not files then
      cb({ parent = root_item, last = true, text = "", sort = " ", comment = "indexing…" })
      return
    end

    local dirs = { [root] = root_item } ---@type table<string, remote.explorer.Item>
    local last = {} ---@type table<remote.explorer.Item, remote.explorer.Item>

    ---@param item remote.explorer.Item
    local function emit(item)
      if last[item.parent] then
        last[item.parent].last = false
      end
      item.last = true
      last[item.parent] = item
      cb(item)
    end

    ---@param url string
    ---@return remote.explorer.Item
    local function dir_item(url)
      if dirs[url] then
        return dirs[url]
      end
      local parent = dir_item(ssh.dirname(url) or root)
      local name = ssh.basename(url)
      ---@type remote.explorer.Item
      local item = {
        file = url,
        _path = url,
        dir = true,
        open = true,
        parent = parent,
        hidden = name:sub(1, 1) == ".",
        text = ssh.relative(url, root),
        sort = parent.sort .. "!" .. name .. " ",
      }
      dirs[url] = item
      emit(item)
      return item
    end

    for _, file in ipairs(files) do
      local name, rel = ssh.basename(file), ssh.relative(file, root)
      if opts.hidden or not (rel:find("^%.") or rel:find("/%.")) then
        local parent = dir_item(ssh.dirname(file) or root)
        emit({
          file = file,
          _path = file,
          parent = parent,
          hidden = name:sub(1, 1) == ".",
          text = rel,
          sort = parent.sort .. "#" .. name .. " ",
        })
      end
    end
  end
end

---@type snacks.picker.finder
function M.finder(opts, ctx)
  local picker = ctx.picker
  local root = root_of(picker)
  if not root then
    -- Only reachable by opening the source directly; the entry points in
    -- `remote/init.lua` ask for a root first.
    vim.schedule(function()
      Snacks.notify.warn("No remote root yet. Connect to a host with `<leader>Rc`.")
    end)
    return {}
  end

  picker.title = title_of(root)
  vim.schedule(function()
    if not picker.closed then
      picker:update_titles()
    end
  end)

  -- Typing filters the whole tree, so keep the directories a match lives in.
  local searching = not ctx.filter:is_empty()
  picker.matcher.opts.keep_parents = searching

  if searching then
    return search_finder(picker, root, opts)
  end
  return tree_finder(picker, root, opts)
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

---@type table<string, snacks.picker.Action.spec>
M.actions = {}

---@param items snacks.picker.Item[]
---@return string[]
local function urls_of(items)
  local urls = {}
  for _, item in ipairs(items) do
    if item.file then
      urls[#urls + 1] = item.file
    end
  end
  return urls
end

function M.actions.confirm(picker, item)
  if not item or not item.file then
    return
  end
  -- In the search view `<CR>` reveals the match in the tree, exactly like the
  -- local explorer. A second `<CR>` then opens it.
  if picker.input.filter.meta.searching then
    return update(picker, { target = item.file })
  end
  if item.dir then
    if expanded[item.file] then
      expanded[item.file] = nil
    else
      expanded[item.file] = true
      failed[item.file] = nil
    end
    return update(picker)
  end
  Open.open(item.file, nil, picker.main)
end

function M.actions.explorer_up(picker)
  local root = root_of(picker)
  local parent = ssh.dirname(root)
  if not parent then
    return Snacks.notify.warn("Already at the filesystem root")
  end
  -- Leave the cursor on the directory we came out of, so `<BS>` then `l` is a
  -- round trip rather than a place to get lost.
  M.set_root(picker, parent, root)
end

function M.actions.explorer_focus(picker)
  M.set_root(picker, dir_of(picker))
end

function M.actions.explorer_close(picker, item)
  if not item or not item.file then
    return
  end
  -- `h` on an open directory closes it, on anything else closes its parent, so
  -- repeated presses walk back up the tree.
  local dir = (item.dir and expanded[item.file]) and item.file or ssh.dirname(item.file)
  if not dir then
    return
  end
  expanded[dir] = nil
  update(picker, { target = dir })
end

--- Every url at or below `root`, in one of the module-level state tables.
---@param state table<string, any>
---@param root string
local function clear_under(state, root)
  for url in pairs(state) do
    if url:sub(1, #root) == root then
      state[url] = nil
    end
  end
end

function M.actions.explorer_close_all(picker)
  local root = root_of(picker)
  clear_under(expanded, root)
  update(picker, { target = root })
end

function M.actions.explorer_update(picker)
  local root = root_of(picker)
  ssh.invalidate(root)
  clear_under(failed, root)
  index[root] = nil
  update(picker)
end

function M.actions.explorer_add(picker)
  local dir = dir_of(picker)
  Snacks.input({ prompt = 'Add a new file or directory (directories end with a "/")' }, function(value)
    if not value or vim.trim(value) == "" then
      return
    end
    local is_dir = value:sub(-1) == "/"
    local url = ssh.join(dir, (vim.trim(value):gsub("/+$", "")))
    local function done(ok, err)
      if not ok then
        return Snacks.notify.error("Failed to create `" .. url .. "`:\n" .. err)
      end
      expanded[is_dir and url or (ssh.dirname(url) or dir)] = true
      update(picker, { target = url })
    end
    if is_dir then
      ssh.mkdir(url, done)
    else
      ssh.touch(url, done)
    end
  end)
end

function M.actions.explorer_del(picker)
  local urls = urls_of(picker:selected({ fallback = true }))
  if #urls == 0 then
    return
  end
  local root = root_of(picker)
  local what = #urls == 1 and ("`" .. display(urls[1], root) .. "`") or (#urls .. " entries")
  -- There is no trash can on the far side of an ssh connection.
  Snacks.picker.util.confirm("Delete " .. what .. " on " .. title_of(root) .. "? This cannot be undone.", function()
    local left = #urls
    for _, url in ipairs(urls) do
      ssh.remove(url, function(ok, err)
        if ok then
          local buf = Open.buf(url)
          if buf then
            Snacks.bufdelete({ buf = buf, force = true })
          end
        else
          Snacks.notify.error("Failed to delete `" .. url .. "`:\n" .. err)
        end
        left = left - 1
        if left == 0 then
          picker.list:set_selected()
          update(picker)
        end
      end)
    end
  end)
end

--- Renaming a path out from under an open buffer would leave that buffer
--- writing back to the old name, and the plugin caches the remote path per
--- buffer, so refuse rather than half-handle it.
---@param urls string[]
---@return boolean ok
local function check_not_open(urls)
  for _, url in ipairs(urls) do
    if Open.buf(url) then
      Snacks.notify.warn("`" .. ssh.basename(url) .. "` is open in a buffer. Close it first.")
      return false
    end
  end
  return true
end

function M.actions.explorer_rename(picker, item)
  if not item or not item.file or not check_not_open({ item.file }) then
    return
  end
  local from = item.file
  Snacks.input({ prompt = "Rename to", default = ssh.basename(from) }, function(value)
    if not value or vim.trim(value) == "" or value == ssh.basename(from) then
      return
    end
    local to = ssh.join(ssh.dirname(from) or root_of(picker), vim.trim(value))
    ssh.rename(from, to, function(ok, err)
      if not ok then
        return Snacks.notify.error("Failed to rename `" .. from .. "`:\n" .. err)
      end
      update(picker, { target = to })
    end)
  end)
end

--- `m` and `c` both move the selection into the directory under the cursor.
---@param picker snacks.Picker
---@param verb string
---@param fn fun(from: string, to: string, cb: fun(ok: boolean, err: string))
local function transfer(picker, verb, fn)
  local urls = urls_of(picker:selected())
  if #urls == 0 then
    return Snacks.notify.warn("Select the entries to " .. verb .. " first (`<Tab>`)")
  end
  local target = dir_of(picker)
  local root = root_of(picker)
  local what = #urls == 1 and ("`" .. display(urls[1], root) .. "`") or (#urls .. " entries")
  Snacks.picker.util.confirm(
    verb:sub(1, 1):upper() .. verb:sub(2) .. " " .. what .. " to `" .. display(target, root) .. "/`?",
    function()
      local left = #urls
      for _, from in ipairs(urls) do
        fn(from, ssh.join(target, ssh.basename(from)), function(ok, err)
          if not ok then
            Snacks.notify.error("Failed to " .. verb .. " `" .. from .. "`:\n" .. err)
          end
          left = left - 1
          if left == 0 then
            picker.list:set_selected()
            expanded[target] = true
            update(picker, { target = target })
          end
        end)
      end
    end
  )
end

function M.actions.explorer_move(picker)
  local urls = urls_of(picker:selected())
  if #urls > 0 and not check_not_open(urls) then
    return
  end
  transfer(picker, "move", ssh.rename)
end

function M.actions.explorer_copy(picker)
  transfer(picker, "copy", ssh.copy)
end

function M.actions.explorer_yank(picker)
  if vim.fn.mode():find("^[vV]") then
    picker.list:select()
  end
  local urls = urls_of(picker:selected({ fallback = true }))
  picker.list:set_selected()
  vim.fn.setreg(vim.v.register or "+", table.concat(urls, "\n"), "l")
  Snacks.notify.info("Yanked " .. #urls .. " remote path" .. (#urls == 1 and "" or "s"))
end

--- Switch to another host or another directory, without closing the explorer.
function M.actions.remote_root(picker)
  require("remote").pick_root(function(url)
    M.set_root(picker, url)
  end)
end

function M.actions.remote_files(picker)
  require("remote").files({ remote_root = dir_of(picker) })
end

function M.actions.remote_grep(picker)
  require("remote").grep({ remote_root = dir_of(picker) })
end

function M.actions.remote_terminal(picker)
  local loc = ssh.parse(dir_of(picker))
  if not loc then
    return
  end
  -- The plugin's own terminal takes its cwd from the current remote buffer, so
  -- ask ssh directly instead and pin it to what the explorer is showing.
  Snacks.terminal({ "ssh", "-t", loc.host, "cd " .. ssh.quote(loc.path) .. " && exec $SHELL -l" })
end

---------------------------------------------------------------------------
-- Source
---------------------------------------------------------------------------

--- Re-run the finder when the pattern flips between empty and non-empty: the
--- tree and the search results are two different views, not two filters over
--- the same items.
---@param opts snacks.picker.Config
function M.config(opts)
  opts.remote_root = opts.remote_root or require("remote").root
  local searching = false
  return Snacks.config.merge(opts, {
    filter = {
      transform = function(_, filter)
        local s = not filter:is_empty()
        if searching ~= s then
          searching = s
          filter.meta.searching = s
          return true
        end
      end,
    },
  })
end

M.source = {
  finder = M.finder,
  config = M.config,
  actions = M.actions,
  preview = Preview.preview,
  format = "file",
  sort = { fields = { "sort" } },
  matcher = { sort_empty = false, fuzzy = false },
  formatters = { file = { filename_only = true } },
  layout = { preset = "sidebar", preview = false },
  supports_live = true,
  hidden = true,
  focus = "list",
  auto_close = false,
  jump = { close = false },
  win = {
    list = {
      keys = {
        ["l"] = "confirm",
        ["h"] = "explorer_close",
        ["<BS>"] = "explorer_up",
        ["."] = "explorer_focus",
        ["u"] = "explorer_update",
        ["a"] = "explorer_add",
        ["d"] = "explorer_del",
        ["r"] = "explorer_rename",
        ["m"] = "explorer_move",
        ["c"] = "explorer_copy",
        ["y"] = { "explorer_yank", mode = { "n", "x" } },
        ["Z"] = "explorer_close_all",
        ["H"] = "toggle_hidden",
        ["P"] = "toggle_preview",
        ["R"] = "remote_root",
        ["f"] = "remote_files",
        ["<leader>/"] = "remote_grep",
        ["<c-t>"] = "remote_terminal",
      },
    },
  },
}

return M
