return {
  "coder/claudecode.nvim",
  opts = {
    terminal = {
      auto_insert = false,
      snacks_win_opts = {
        keys = {
          nav_h = { "<C-h>", function() vim.cmd("stopinsert"); vim.cmd.wincmd("h") end, mode = "t", desc = "Left window" },
          nav_j = { "<C-j>", function() vim.cmd("stopinsert"); vim.cmd.wincmd("j") end, mode = "t", desc = "Lower window" },
          nav_k = { "<C-k>", function() vim.cmd("stopinsert"); vim.cmd.wincmd("k") end, mode = "t", desc = "Upper window" },
          nav_l = { "<C-l>", function() vim.cmd("stopinsert"); vim.cmd.wincmd("l") end, mode = "t", desc = "Right window" },
        },
      },
    },
  },
}
