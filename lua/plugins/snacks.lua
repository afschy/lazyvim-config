return {
    "folke/snacks.nvim",
    opts = {
        picker = {
            -- `remote_explorer`, `remote_files`, `remote_grep` and
            -- `remote_buffers`: the same pickers, reading another machine over
            -- ssh. See lua/remote/.
            sources = vim.tbl_extend("error", require("remote").sources, {
                explorer = {
                    hidden = true,   -- dotfiles
                    ignored = true,  -- gitignored
                },
            }),
        },
    },
}
