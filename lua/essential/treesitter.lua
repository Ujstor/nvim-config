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

    require('nvim-treesitter').setup {
      ensure_installed = {
        'bash',
        'c',
        'lua',
        'vim',
        'vimdoc',
        'markdown',
        'markdown_inline',
        'diff',
        'hcl',
        'terraform',
        'dockerfile',
        'yaml',
        'json',
        'jsonc',
        'toml',
        'ini',
        'go',
        'python',
        'javascript',
        'typescript',
        'html',
        'css',
        'make',
        'cmake',
        'git_config',
        'git_rebase',
        'gitattributes',
        'gitcommit',
        'gitignore',
        'fish',
        'tmux',
        'ssh_config',
        'csv',
        'xml',
        'proto',
        'sql',
        'rst',
        'nginx',
        'groovy',
      },

      auto_install = true,
    }

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
