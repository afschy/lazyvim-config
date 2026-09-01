-- ~/.config/nvim/lua/plugins/image.lua
return {
  "3rd/image.nvim",
  event = "VeryLazy",
  opts = {
    backend = "sixel",
    processor = "magick_cli",
    integrations = { markdown = { enabled = true } },
    hijack_file_patterns = { "*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp" },
  },
  config = function(_, opts)
    require("image").setup(opts)

    local api = require("image")
    local cache = vim.fn.stdpath("cache") .. "/pdfview"
    vim.fn.mkdir(cache, "p")

    local state = {} ---@type table<number, {file:string, page:number, total:number, img:table?}>

    local function page_count(file)
      if vim.fn.executable("pdfinfo") == 1 then
        local n = tonumber(vim.fn.system({ "pdfinfo", file }):match("Pages:%s+(%d+)"))
        if n then return n end
      end
      if vim.fn.executable("gs") == 1 then
        local n = tonumber(vim.trim(vim.fn.system({
          "gs", "-q", "-dNODISPLAY", "-dNOSAFER", "-c",
          ("(%s) (r) file runpdfbegin pdfpagecount = quit"):format(file),
        })))
        if n then return n end
      end
      return math.huge
    end

    local function render(buf)
      local st, win = state[buf], vim.fn.bufwinid(buf)
      if not st or win == -1 then return end

      local cell = require("image.utils.term").get_size()
      local w = math.floor(vim.api.nvim_win_get_width(win) * cell.cell_width)
      local h = math.floor((vim.api.nvim_win_get_height(win) - 1) * cell.cell_height)
      local png = ("%s/%s-p%d-%dx%d.png"):format(cache, vim.fn.sha256(st.file):sub(1, 12), st.page, w, h)

      if vim.fn.filereadable(png) == 0 then
        vim.fn.system({
          "magick", "-density", "200", ("%s[%d]"):format(st.file, st.page - 1),
          "-background", "white", "-alpha", "remove", "-trim",
          "-resize", ("%dx%d"):format(w, h), png,
        })
        if vim.v.shell_error ~= 0 then
          return vim.notify("magick failed on page " .. st.page, vim.log.levels.ERROR)
        end
      end

      if st.img then st.img:clear() end
      st.img = api.from_file(png, { window = win, buffer = buf, x = 0, y = 0 })
      st.img:render()
      vim.wo[win].winbar = (" %s   %d/%s"):format(
        vim.fn.fnamemodify(st.file, ":t"), st.page, st.total == math.huge and "?" or st.total)
    end

    local function goto_page(buf, page)
      local st = state[buf]
      st.page = math.max(1, math.min(page, st.total))
      render(buf)
    end

    vim.api.nvim_create_autocmd("BufReadCmd", {
      pattern = "*.pdf",
      callback = function(ev)
        local file = vim.api.nvim_buf_get_name(ev.buf)
        vim.bo[ev.buf].buftype = "nofile"
        vim.bo[ev.buf].swapfile = false
        vim.bo[ev.buf].modifiable = false
        vim.bo[ev.buf].filetype = "pdf"
        state[ev.buf] = { file = file, page = 1, total = page_count(file) }

        local function map(lhs, fn, desc)
          vim.keymap.set("n", lhs, fn, { buffer = ev.buf, desc = desc })
        end
        map("]]", function() goto_page(ev.buf, state[ev.buf].page + vim.v.count1) end, "PDF: next page")
        map("[[", function() goto_page(ev.buf, state[ev.buf].page - vim.v.count1) end, "PDF: prev page")
        map("gg", function() goto_page(ev.buf, vim.v.count > 0 and vim.v.count or 1) end, "PDF: goto page")
        map("G", function() goto_page(ev.buf, vim.v.count > 0 and vim.v.count or state[ev.buf].total) end, "PDF: last")

        vim.schedule(function() render(ev.buf) end)
      end,
    })

    vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
      callback = function()
        for buf in pairs(state) do render(buf) end
      end,
    })

    vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
      callback = function(ev)
        local st = state[ev.buf]
        if st and st.img then st.img:clear() end
        state[ev.buf] = nil
      end,
    })
  end,
}
