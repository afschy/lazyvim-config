-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here
-- lua/config/options.lua
-- Copy to the *local* system clipboard over ssh/mosh via OSC 52.
-- Neovim only auto-enables OSC 52 when g:termfeatures.osc52 is true
-- (provider/clipboard.vim), which requires the terminal to answer nvim's
-- capability probe. mosh emulates the terminal server-side and never relays
-- that answer, so the flag stays false and we must set g:clipboard ourselves.
-- mosh does forward SSH_TTY/SSH_CONNECTION, so those are enough to detect.
if vim.env.SSH_TTY or vim.env.SSH_CONNECTION or vim.env.NVIM_OSC52 then
    local osc52 = require("vim.ui.clipboard.osc52")
    -- Paste falls back to the unnamed register: a real osc52.paste() sends a
    -- query and blocks waiting for a reply mosh will not deliver.
    local paste = function()
        return vim.split(vim.fn.getreg(""), "\n")
    end
    vim.g.clipboard = {
        name = "OSC 52",
        copy = { ["+"] = osc52.copy("+"), ["*"] = osc52.copy("*") },
        paste = { ["+"] = paste, ["*"] = paste },
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
