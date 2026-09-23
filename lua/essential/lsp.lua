return { -- LSP Configuration & Plugins
  'neovim/nvim-lspconfig',
  dependencies = {
    -- Automatically install LSPs and related tools to stdpath for neovim
    'williamboman/mason.nvim',
    'williamboman/mason-lspconfig.nvim',
    'WhoIsSethDaniel/mason-tool-installer.nvim',
    -- Useful status updates for LSP.
    -- NOTE: `opts = {}` is the same as calling `require('fidget').setup({})`
    { 'j-hui/fidget.nvim', opts = {} },
  },
  config = function()
    -- Brief Aside: **What is LSP?**
    --
    -- LSP is an acronym you've probably heard, but might not understand what it is.
    --
    -- LSP stands for Language Server Protocol. It's a protocol that helps editors
    -- and language tooling communicate in a standardized fashion.
    --
    -- In general, you have a "server" which is some tool built to understand a particular
    -- language (such as `gopls`, `lua_ls`, `rust_analyzer`, etc). These Language Servers
    -- (sometimes called LSP servers, but that's kind of like ATM Machine) are standalone
    -- processes that communicate with some "client" - in this case, Neovim!
    --
    -- LSP provides Neovim with features like:
    --  - Go to definition
    --  - Find references
    --  - Autocompletion
    --  - Symbol Search
    --  - and more!
    --
    -- Thus, Language Servers are external tools that must be installed separately from
    -- Neovim. This is where `mason` and related plugins come into play.
    --
    -- If you're wondering about lsp vs treesitter, you can check out the wonderfully
    -- and elegantly composed help section, :help lsp-vs-treesitter
    --  This function gets run when an LSP attaches to a particular buffer.
    --    That is to say, every time a new file is opened that is associated with
    --    an lsp (for example, opening `main.rs` is associated with `rust_analyzer`) this
    --    function will be executed to configure the current buffer
    vim.api.nvim_create_autocmd('LspAttach', {
      group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
      callback = function(event)
        -- NOTE: Remember that lua is a real programming language, and as such it is possible
        -- to define small helper and utility functions so you don't have to repeat yourself
        -- many times.
        --
        -- In this case, we create a function that lets us more easily define mappings specific
        -- for LSP related items. It sets the mode, buffer and description for us each time.
        local map = function(keys, func, desc, opts)
          vim.keymap.set('n', keys, func, vim.tbl_extend('force', { buffer = event.buf, desc = 'LSP: ' .. desc }, opts or {}))
        end
        -- Jump to the definition of the word under your cursor.
        --  This is where a variable was first declared, or where a function is defined, etc.
        --  To jump back, press <C-T>.
        map('gd', require('telescope.builtin').lsp_definitions, '[G]oto [D]efinition')
        -- Find references for the word under your cursor.
        -- nowait: nvim 0.11+ maps grn/grr/gra/gri/grt/grx globally, so without it
        -- `gr` sat out 'timeoutlen' every time, waiting to see if one was meant.
        map('gr', require('telescope.builtin').lsp_references, '[G]oto [R]eferences', { nowait = true })
        -- Jump to the implementation of the word under your cursor.
        --  Useful when your language has ways of declaring types without an actual implementation.
        map('gI', require('telescope.builtin').lsp_implementations, '[G]oto [I]mplementation')
        -- Jump to the type of the word under your cursor.
        --  Useful when you're not sure what type a variable is and you want to see
        --  the definition of its *type*, not where it was *defined*.
        map('<leader>D', require('telescope.builtin').lsp_type_definitions, 'Type [D]efinition')
        -- Fuzzy find all the symbols in your current document.
        --  Symbols are things like variables, functions, types, etc.
        map('<leader>ds', require('telescope.builtin').lsp_document_symbols, '[D]ocument [S]ymbols')
        -- Fuzzy find all the symbols in your current workspace
        --  Similar to document symbols, except searches over your whole project.
        map('<leader>ws', require('telescope.builtin').lsp_dynamic_workspace_symbols, '[W]orkspace [S]ymbols')
        -- Rename the variable under your cursor
        --  Most Language Servers support renaming across files, etc.
        map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
        -- Execute a code action, usually your cursor needs to be on top of an error
        -- or a suggestion from your LSP for this to activate.
        map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction')
        -- Opens a popup that displays documentation about the word under your cursor
        --  See `:help K` for why this keymap
        map('K', vim.lsp.buf.hover, 'Hover Documentation')
        -- WARN: This is not Goto Definition, this is Goto Declaration.
        --  For example, in C this would take you to the header
        map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')
        -- The following two autocommands are used to highlight references of the
        -- word under your cursor when your cursor rests there for a little while.
        --    See `:help CursorHold` for information about when this is executed
        --
        -- When you move your cursor, the highlights will be cleared (the second autocommand).
        local client = vim.lsp.get_client_by_id(event.data.client_id)
        if client and client.server_capabilities.documentHighlightProvider then
          vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
            buffer = event.buf,
            callback = vim.lsp.buf.document_highlight,
          })
          vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
            buffer = event.buf,
            callback = vim.lsp.buf.clear_references,
          })
        end
      end,
    })
    -- Enable the following language servers
    -- mason-lspconfig.nvim will automatically enable (via vim.lsp.enable()) installed servers
    -- You can configure servers using vim.lsp.config() or lspconfig
    -- Initialize Mason first
    require('mason').setup()

    -- Some mason packages are BUILT here: npm packages need npm, gopls and delve
    -- need go. On a box without one (root's nvim, where node comes from a per-user
    -- nvm; any box without go) asking for them failed at every launch with a
    -- "Press ENTER" prompt. They are asked for only when the toolchain is on PATH,
    -- and appear on the next launch after it is.
    local function needs(tool, list)
      return vim.fn.executable(tool) == 1 and list or {}
    end

    local servers = {
      -- Language servers only (these are actual LSP servers)
      'clangd',
      'lua_ls',
      'rust_analyzer', -- Rust
      'marksman', -- Markdown
      'terraformls', -- Terraform
      -- Add other servers you want automatically installed
    }
    vim.list_extend(servers, needs('go', { 'gopls' }))
    vim.list_extend(
      servers,
      needs('npm', {
        'ansiblels',
        'bashls',
        'dockerls',
        'docker_compose_language_service',
        'ts_ls', -- Changed from tsserver to ts_ls
        'pyright', -- Python
      })
    )
    -- Configure mason-lspconfig with ensure_installed servers
    -- Note: automatic_enable requires Neovim 0.11+
    require('mason-lspconfig').setup {
      ensure_installed = servers,
      automatic_enable = true, -- Disable if using Neovim < 0.11
    }
    -- Install additional tools (non-LSP servers) via mason-tool-installer
    require('mason-tool-installer').setup {
      ensure_installed = vim.list_extend({
        'stylua', -- Lua formatter
        'shellcheck', -- Shell linter
        'tfsec', -- Terraform security
        'tflint', -- Terraform linter
        -- Add other linters/formatters here
      }, needs('npm', { 'prettier' })), -- Web formatter
    }
    -- Configure LSP capabilities for nvim-cmp completion
    local capabilities = require('cmp_nvim_lsp').default_capabilities()

    -- Set default capabilities for all LSP servers
    -- Note: mason-lspconfig with automatic_enable = true will automatically
    -- call vim.lsp.enable() for all installed servers
    vim.lsp.config('*', {
      capabilities = capabilities,
    })

    -- marksman is a .NET binary, and .NET aborts at startup where libicu is not
    -- installed ("Couldn't find a valid ICU package"), which a minimal server or
    -- container often lacks: every markdown buffer then said "Client marksman quit
    -- with exit code 0 and signal 6". Reading markdown needs no locale data, so
    -- it runs in .NET's invariant mode everywhere.
    vim.lsp.config('marksman', {
      cmd_env = { DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = '1' },
    })

    -- Configure lua_ls with custom settings for Neovim development
    vim.lsp.config.lua_ls = {
      capabilities = capabilities,
      settings = {
        Lua = {
          runtime = { version = 'LuaJIT' },
          workspace = {
            checkThirdParty = false,
            -- Tells lua_ls where to find all the Lua files that you have loaded
            -- for your neovim configuration.
            library = {
              '${3rd}/luv/library',
              unpack(vim.api.nvim_get_runtime_file('', true)),
            },
            -- If lua_ls is really slow on your computer, you can try this instead:
            -- library = { vim.env.VIMRUNTIME },
          },
          completion = {
            callSnippet = 'Replace',
          },
          -- You can toggle below to ignore Lua_LS's noisy `missing-fields` warnings
          -- diagnostics = { disable = { 'missing-fields' } },
        },
      },
    }
  end,
}
