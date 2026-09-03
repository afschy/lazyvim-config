--- Previews for remote items.
---
--- Snacks' own file previewer would `bufadd` the url and `bufload` it, which
--- remote-ssh.nvim's `BufReadCmd` turns into a real file open in a real window.
--- Moving the cursor in a picker must not do that, so previews get their own
--- path: fetch the head of the file over ssh and drop it in the scratch buffer.

local ssh = require("remote.ssh")

local M = {}

---@param url string
---@return string|nil
local function filetype(url)
  local loc = ssh.parse(url)
  return loc and vim.filetype.match({ filename = loc.path }) or nil
end

---@param ctx snacks.picker.preview.ctx
---@param url string
local function preview_dir(ctx, url)
  ctx.preview:reset()
  ctx.preview:set_title(ssh.basename(url))

  ---@param entries remote.Entry[]
  local function render(entries)
    local lines = {}
    for _, e in ipairs(entries) do
      lines[#lines + 1] = e.dir and (e.name .. "/") or e.name
    end
    ctx.preview:set_lines(#lines > 0 and lines or { "(empty)" })
  end

  local cached = ssh.cached(url)
  if cached then
    return render(cached)
  end
  ctx.preview:spinner(true)
  ssh.ls(url, function(ok, entries, err)
    if ctx.preview.item ~= ctx.item or not ctx.preview.win:buf_valid() then
      return
    end
    ctx.preview:spinner(false)
    if not ok then
      return ctx.preview:notify(err ~= "" and err or "could not list directory", "error")
    end
    render(entries)
  end)
end

---@param ctx snacks.picker.preview.ctx
function M.preview(ctx)
  local item = ctx.item

  -- Already open locally: show the real buffer, syntax and all.
  if item.buf and vim.api.nvim_buf_is_loaded(item.buf) then
    ctx.preview:set_title(ssh.basename(vim.api.nvim_buf_get_name(item.buf)))
    ctx.preview:set_buf(item.buf)
    ctx.preview:loc()
    return
  end

  local url = item.file
  if not url or not ssh.is_remote(url) then
    return ctx.preview:reset()
  end
  if item.dir then
    return preview_dir(ctx, url)
  end

  ctx.preview:reset()
  ctx.preview:set_title(ssh.basename(url))
  ctx.preview:spinner(true)
  ssh.read(url, function(ok, lines, err)
    -- The cursor moved on while we were waiting; this content is stale.
    if ctx.preview.item ~= item or not ctx.preview.win:buf_valid() then
      return
    end
    ctx.preview:spinner(false)
    if not ok then
      return ctx.preview:notify(err ~= "" and err or "could not read file", "error")
    end
    ctx.preview:set_lines(lines)
    ctx.preview:highlight({ ft = filetype(url) })
    ctx.preview:loc()
  end)
end

return M
