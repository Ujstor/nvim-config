return {
  'nvim-treesitter/nvim-treesitter',
  branch = 'main',
  build = ':TSUpdate',
  config = function()
    -- nvim-treesitter main branch stores bundled queries in runtime/queries/
    -- but lazy.nvim only adds the plugin root to rtp, not the runtime/ subdir.
    -- Add it explicitly so queries are found before :TSUpdate installs them to site/.
    local ts_runtime = vim.fn.stdpath 'data' .. '/lazy/nvim-treesitter/runtime'
    if vim.fn.isdirectory(ts_runtime) == 1 then
      vim.opt.rtp:append(ts_runtime)
    end

    require('nvim-treesitter').setup {}

    -- main branch dropped `ensure_installed` / `auto_install` from setup().
    -- Install any missing parsers ourselves by checking the runtime path.
    -- Names absent from nvim-treesitter's registry are skipped here: they can
    -- never install, so they'd otherwise be re-attempted on every startup and
    -- log "skipping unsupported language: <name>" each time.
    local registry = require 'nvim-treesitter.parsers'
    local ensure_installed = require 'parsers'
    local missing = {}
    for _, lang in ipairs(ensure_installed) do
      if registry[lang] ~= nil and #vim.api.nvim_get_runtime_file('parser/' .. lang .. '.so', false) == 0 then
        table.insert(missing, lang)
      end
    end
    if #missing > 0 then
      require('nvim-treesitter').install(missing)
    end

    -- Highlight and indent are now controlled by neovim natively (0.12+)
    -- nvim-treesitter main branch no longer manages these via configs module
    vim.api.nvim_create_autocmd('FileType', {
      callback = function(ev)
        local buf = ev.buf
        local ok, stats = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(buf))
        if ok and stats and stats.size > 100 * 1024 then
          return
        end
        if vim.api.nvim_buf_line_count(buf) > 5000 then
          return
        end
        pcall(vim.treesitter.start, buf)
      end,
    })
  end,
}
