--- Handing a remote file over to remote-ssh.nvim.
---
--- Everything else in `remote/` only reads over ssh. This is the one place that
--- creates a buffer, and it deliberately goes through the plugin so the buffer
--- is the one its rsync writer and its remote LSP client already know about.

local ssh = require("remote.ssh")

local M = {}

local loaded = false

--- remote-ssh.nvim stays lazy: browsing does not need it, and loading it starts
--- LSP and file-watching machinery. `lazy.load` is a no-op once it is in.
---@return table|nil operations the async-remote-write operations module
function M.ensure()
  if not loaded then
    pcall(function()
      require("lazy").load({ plugins = { "remote-ssh.nvim" } })
    end)
    loaded = true
  end
  local ok, ops = pcall(require, "async-remote-write.operations")
  if not ok then
    Snacks.notify.error("remote-ssh.nvim is not available:\n" .. tostring(ops))
    return nil
  end
  return ops
end

--- Record the open so it shows up under "recent roots" next session.
---@param url string
---@param kind? "file"|"tree"
function M.track(url, kind)
  local ok, history = pcall(require, "async-remote-write.session_picker")
  if not ok then
    return
  end
  if kind == "tree" then
    history.track_tree_browser_open(url, {})
  else
    history.track_file_open(url, {})
  end
end

--- Buffer holding `url`, if we already have one. Buffer names are the urls
--- themselves, so an exact match is all it takes.
---@param url string
---@return integer|nil
function M.buf(url)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == url then
      return buf
    end
  end
end

--- Show a buffer we already have, without going near the network.
---@param buf integer
---@param pos? integer[]
---@param win? integer
function M.show(buf, pos, win)
  win = win and vim.api.nvim_win_is_valid(win) and win or vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_set_current_win(win)
  if pos then
    pcall(vim.api.nvim_win_set_cursor, win, { pos[1], pos[2] or 0 })
    vim.api.nvim_win_call(win, function()
      vim.cmd("normal! zz")
    end)
  end
end

--- Open a remote file.
---@param url string
---@param pos? integer[] {line, col}, 1-based line and 0-based column
---@param win? integer window to open it in
function M.open(url, pos, win)
  if not ssh.is_remote(url) then
    return Snacks.notify.error("not a remote url:\n- `" .. tostring(url) .. "`")
  end
  -- Going through the plugin again would re-fetch the file and replace the
  -- buffer's contents, throwing away anything unsaved. If we already have it,
  -- just show it.
  local buf = M.buf(url)
  if buf and vim.api.nvim_buf_is_loaded(buf) then
    return M.show(buf, pos, win)
  end
  local ops = M.ensure()
  if not ops then
    return
  end
  ops.simple_open_remote_file(url, pos, win)
  M.track(url)
end

return M
