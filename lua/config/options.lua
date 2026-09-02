-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
-- lua/config/options.lua
-- lua/config/options.lua
local is_remote = vim.env.NVIM_OSC52
if is_remote then
    local osc52 = require("vim.ui.clipboard.osc52")
    vim.g.clipboard = {
        name = "OSC 52",
        copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("+") },
        paste = { ["+"] = function() return {} end, ["*"] = function() return {} end },
    }
end
vim.opt.relativenumber = true -- makes 5j / 12k natural
vim.opt.scrolloff = 8
-- vim.opt.colorcolumn = "100"
vim.opt.expandtab = true
vim.g.autoformat = false
vim.opt.shiftwidth = 4
vim.o.mousemoveevent = true
vim.api.nvim_create_autocmd("CursorHold", {
    callback = function()
    vim.diagnostic.open_float(nil, { focus = false })
    end,
})
vim.o.updatetime = 500
