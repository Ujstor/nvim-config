return { -- Highlight, edit, and navigate code
  'nvim-treesitter/nvim-treesitter',
  build = ':TSUpdate',
  config = function()
    -- [[ Configure Treesitter ]] See `:help nvim-treesitter`
    ---@diagnostic disable-next-line: missing-fields
    require('nvim-treesitter.configs').setup {
      ensure_installed = {
        -- Core languages
        'bash',
        'c',
        'lua',
        'vim',
        'vimdoc',
        'markdown',
        'markdown_inline',
        'diff',
        'hcl', -- Terraform
        'terraform', -- Terraform specific
        'dockerfile', -- Docker
        'yaml', -- Kubernetes, CI/CD, configs
        'json', -- Configuration files
        'jsonc', -- JSON with comments
        'toml', -- Configuration files
        'ini', -- Configuration files
        -- 'helm', -- Disabled: causes injection query nil node errors (treesitter bug)
        'go', -- Go applications, tools
        'python', -- Scripts, automation
        'javascript', -- Node.js tools
        'typescript', -- Modern JS tooling
        'html',
        'css',
        'make', -- Makefiles
        'cmake', -- Build systems
        'git_config',
        'git_rebase',
        'gitattributes',
        'gitcommit',
        'gitignore',
        'fish', -- Fish shell
        'tmux', -- Tmux config
        'ssh_config', -- SSH configuration
        'csv', -- Data processing
        'xml', -- Configuration files
        'proto', -- Protocol buffers
        'sql', -- Database queries
        'rst', -- reStructuredText
        'nginx', -- Nginx configuration
        'groovy', -- Jenkins pipelines
      },

      -- Autoinstall languages that are not installed
      auto_install = true,

      highlight = {
        enable = true,
        disable = function(lang, buf)
          -- Disable for very large files
          local max_filesize = 100 * 1024 -- 100 KB
          local ok, stats = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(buf))
          if ok and stats and stats.size > max_filesize then
            return true
          end

          -- Disable for buffers with too many lines
          local line_count = vim.api.nvim_buf_line_count(buf)
          if line_count > 5000 then
            return true
          end

          -- Guard against parsers that return nil (Neovim 0.12 breaking change)
          local parser_ok = pcall(vim.treesitter.get_parser, buf, lang)
          if not parser_ok then
            return true
          end
        end,
        additional_vim_regex_highlighting = false,
      },

      indent = { enable = true },

      -- Disabled: incremental_selection triggers nil node errors on Neovim 0.12
      incremental_selection = { enable = false },
    }

    -- There are additional nvim-treesitter modules that you can use to interact
    -- with nvim-treesitter. You should go explore a few and see what interests you:
    --
    --    - Incremental selection: Included, see :help nvim-treesitter-incremental-selection-mod
    --    - Show your current context: https://github.com/nvim-treesitter/nvim-treesitter-context
    --    - Treesitter + textobjects: https://github.com/nvim-treesitter/nvim-treesitter-textobjects
  end,
}
