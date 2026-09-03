-- lua/plugins/colorscheme.lua
return {
    {
        "projekt0n/github-nvim-theme",
        name = "github-theme",
        lazy = false,
        priority = 1000,
    },
    {
        "ellisonleao/gruvbox.nvim",
        lazy = false,
        priority = 1000,
    },
    -- Make github-light the active colorscheme.
    {
        "LazyVim/LazyVim",
        opts = {
            colorscheme = "github_light",
        },
    },
}
