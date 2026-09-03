--- Working on files that live on another machine.
---
--- remote-ssh.nvim supplies the buffers: it fetches a file into an `acwrite`
--- buffer named `rsync://user@host//path`, rsyncs it back on `:w`, and runs the
--- language server over on the far side. `lua/remote/` supplies the other half,
--- the snacks pickers that browse that machine, so choosing a file feels the
--- same as it does locally.
---
--- Telescope is deliberately not a dependency. The README asks for it, but every
--- `require("telescope")` in the plugin is a `pcall` inside its own browser,
--- which nothing here uses.
return {
  {
    "inhesrom/remote-ssh.nvim",
    branch = "master",
    dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
    cmd = {
      "RemoteOpen",
      "RemoteGrep",
      "RemoteRefresh",
      "RemoteRefreshAll",
      "RemoteHistory",
      "RemoteLspStart",
      "RemoteLspStop",
      "RemoteLspRestart",
      "RemoteLspServers",
      "RemoteTerminalToggle",
      "RemoteTerminalNew",
      "RemoteSessionPicker",
      "AsyncWriteStatus",
      "AsyncWriteCancel",
    },
    keys = {
      -- Browsing needs nothing but ssh, so these load the plugin a little
      -- earlier than strictly necessary. The first file you open needs it
      -- anyway, and keeping the whole feature on one keymap prefix is worth
      -- more than the milliseconds.
      {
        "<leader>Rc",
        function()
          require("remote").connect()
        end,
        desc = "Connect to Host",
      },
      {
        "<leader>Re",
        function()
          require("remote").explorer()
        end,
        desc = "Explorer",
      },
      {
        "<leader>Rf",
        function()
          require("remote").files()
        end,
        desc = "Find Files",
      },
      {
        "<leader>Rg",
        function()
          require("remote").grep()
        end,
        desc = "Grep",
      },
      {
        "<leader>Rb",
        function()
          require("remote").buffers()
        end,
        desc = "Buffers",
      },
      {
        "<leader>Rt",
        function()
          require("remote").terminal()
        end,
        desc = "Terminal",
      },
      {
        "<leader>Rd",
        function()
          require("remote").disconnect()
        end,
        desc = "Drop SSH Connections",
      },
    },
    config = function()
      -- LazyVim registers its LSP keymaps for every client name (the `"*"`
      -- server entry), so a `remote_clangd` picks them up like any other
      -- client and there is nothing to do on attach but stay quiet.
      local ok, blink = pcall(require, "blink.cmp")
      require("remote-ssh").setup({
        on_attach = function() end,
        capabilities = ok and blink.get_lsp_capabilities() or vim.lsp.protocol.make_client_capabilities(),
      })
    end,
  },
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>R", group = "remote", icon = { icon = "󰢹 ", color = "cyan" } },
      },
    },
  },
}
