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

        -- DevOps & Infrastructure as Code
        'hcl', -- Terraform
        'terraform', -- Terraform specific
        'dockerfile', -- Docker
        'yaml', -- Kubernetes, CI/CD, configs
        'json', -- Configuration files
        'jsonc', -- JSON with comments
        'toml', -- Configuration files
        'ini', -- Configuration files

        -- Cloud & Kubernetes
        'helm', -- Helm charts

        -- Programming languages for scripts/tools
        'go', -- Go applications, tools
        'python', -- Scripts, automation
        'javascript', -- Node.js tools
        'typescript', -- Modern JS tooling

        -- Web technologies (for dashboards, frontends)
        'html',
        'css',

        -- CI/CD & Automation
        'make', -- Makefiles
        'cmake', -- Build systems

        -- Version Control & Git
        'git_config',
        'git_rebase',
        'gitattributes',
        'gitcommit',
        'gitignore',

        -- Shell & System
        'fish', -- Fish shell
        'tmux', -- Tmux config
        'ssh_config', -- SSH configuration

        -- Data formats
        'csv', -- Data processing
        'xml', -- Configuration files

        -- Security & Compliance
        'proto', -- Protocol buffers
        'sql', -- Database queries

        -- Documentation
        'rst', -- reStructuredText

        -- Optional but useful for DevOps
        'nginx', -- Nginx configuration
        'groovy', -- Jenkins pipelines
        -- Note: Ansible syntax highlighting comes via yaml parser
      },

      -- Autoinstall languages that are not installed
      auto_install = true,

      highlight = {
        enable = true,
        -- Disable for very large files to maintain performance
        disable = function(lang, buf)
          local max_filesize = 100 * 1024 -- 100 KB
          local ok, stats = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(buf))
          if ok and stats and stats.size > max_filesize then
            return true
          end
        end,
      },

      indent = { enable = true },

      -- Enable incremental selection (useful for editing complex configs)
      incremental_selection = {
        enable = true,
        keymaps = {
          init_selection = 'gnn',
          node_incremental = 'grn',
          scope_incremental = 'grc',
          node_decremental = 'grm',
        },
      },
    }

    -- There are additional nvim-treesitter modules that you can use to interact
    -- with nvim-treesitter. You should go explore a few and see what interests you:
    --
    --    - Incremental selection: Included, see :help nvim-treesitter-incremental-selection-mod
    --    - Show your current context: https://github.com/nvim-treesitter/nvim-treesitter-context
    --    - Treesitter + textobjects: https://github.com/nvim-treesitter/nvim-treesitter-textobjects
  end,
}
