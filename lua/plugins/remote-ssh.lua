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

        -- Files save on `:w` and at no other time, the same as local ones.
        -- The plugin otherwise rsyncs the buffer whenever you stop changing it
        -- for three seconds, which is a debounce rather than an interval: the
        -- timer restarts on every keystroke and only fires from normal mode.
        -- The language server does not need it -- remote-lsp attaches through
        -- `vim.lsp.buf_attach_client`, so Neovim streams `didChange` and clangd
        -- reads an open buffer live whether or not it has been written. What
        -- does read the far side's disk is a build in `<leader>Rt` and the
        -- `<leader>Rf` / `<leader>Rg` pickers, and for those an explicit save
        -- beats racing a timer. It also gives `modified` its meaning back.
        async_write_opts = { autosave = false },
      })

      -- netrw claims `scp://` and `rsync://` as well, so writing one of these
      -- buffers ran netrw's handler alongside the plugin's. The plugin defuses
      -- that by pointing `g:netrw_rsync_cmd` at an `echo`, which still costs a
      -- shell command and a "Press ENTER" prompt on every `:w` -- invisible
      -- while autosave was on, because autosave never went through `:w`. Hand
      -- both schemes to the plugin outright; netrw keeps http://, ftp:// and
      -- its own browser.
      pcall(vim.api.nvim_clear_autocmds, {
        group = "Network",
        pattern = { "scp://*", "rsync://*" },
      })

      -- One ssh for the whole project-root climb instead of one per directory
      -- level, and cached by directory rather than by file. See `remote.lsp`.
      require("remote.lsp").setup()

      -- Every ssh the plugin spawns asks for `ControlMaster=no ControlPath=none`,
      -- and a command-line `-o` beats the config file, so each one opts out of
      -- the multiplexing `~/.ssh/config` sets up under `Host *` and pays a full
      -- handshake. That is most of the cost of a save: the `mkdir -p` the plugin
      -- runs before every write (`operations.lua:846`) is a whole key exchange
      -- on its own, and against a VM doing software crypto it ran to four
      -- seconds. Drop the two options and the calls fall through to the shared
      -- master -- which also keeps that master warm for the rsync behind it,
      -- since rsync is spawned without `-e` and picks up the same config.
      local ssh_utils = require("async-remote-write.ssh_utils")
      local function share_connection(argv)
        local out, i = {}, 1
        while i <= #argv do
          local opt = argv[i] == "-o" and argv[i + 1]
          if opt == "ControlMaster=no" or opt == "ControlPath=none" then
            i = i + 2
          else
            out[#out + 1] = argv[i]
            i = i + 1
          end
        end
        return out
      end
      for _, name in ipairs({ "build_ssh_cmd", "build_ssh_command" }) do
        local build = ssh_utils[name]
        ssh_utils[name] = function(...)
          return share_connection(build(...))
        end
      end

      -- Every remote buffer otherwise gets a five-second `stat` poll watching for
      -- edits made by somebody else, and it mistakes your own saves for them.
      -- `rsync -a` carries the staged file's timestamp across, so the remote
      -- mtime is stamped when the save *starts*, while the plugin records the
      -- save as having happened when rsync *finishes*; more than five seconds
      -- between the two and it rules the change an outside edit. Save over a
      -- link slower than that and the next poll either warns "Conflict detected:
      -- remote file changed" or silently fetches the file back over the buffer
      -- you are typing in. Clock skew between the two machines does the same
      -- whenever the far side will not let rsync set mtimes. The poll asks for
      -- ControlMaster=no as well, so it costs a fresh SSH handshake per buffer
      -- every five seconds.
      --
      -- Nothing starts it now. `:RemoteWatchStart` still does, one buffer at a
      -- time, for a file somebody else really is editing.
      local watcher = require("async-remote-write.file-watcher")
      local start = watcher.start_watching
      watcher.start_watching = function()
        return false
      end
      vim.api.nvim_create_user_command("RemoteWatchStart", function()
        local buf = vim.api.nvim_get_current_buf()
        if start(buf) then
          vim.notify("Watching " .. vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t") .. " for outside changes")
        else
          vim.notify("Not a remote buffer", vim.log.levels.ERROR)
        end
      end, { desc = "Watch the current remote file for outside changes" })
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
