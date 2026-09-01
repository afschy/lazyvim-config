-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here
local map = vim.keymap.set
map("t", "<C-h>", "<C-\\><C-n><C-w>h")
map("t", "<C-l>", "<C-\\><C-n><C-w>l")
map("n", "<leader>cH", "<cmd>ClangdSwitchSourceHeader<cr>", { desc = "Header/Source" })
map("n", "<leader>m", "<cmd>make<cr>", { desc = "Build" })
