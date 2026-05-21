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

    -- Shim removed APIs from nvim-treesitter master so plugins (telescope, etc.)
    -- written against the old API keep working on the main-branch rewrite.
    -- Why a function + autocmd: install.lua does `package.loaded['nvim-treesitter.parsers'] = nil`
    -- after every parser install/update and fires User TSUpdate, which wipes shims set once.
    local function apply_parsers_shim()
      local ok, parsers = pcall(require, 'nvim-treesitter.parsers')
      if not ok then
        return
      end
      if not parsers.ft_to_lang then
        parsers.ft_to_lang = function(ft)
          return vim.treesitter.language.get_lang(ft) or ft
        end
      end
      if not parsers.get_buf_lang then
        parsers.get_buf_lang = function(bufnr)
          local ft = vim.bo[bufnr or 0].filetype
          return vim.treesitter.language.get_lang(ft) or ft
        end
      end
      if not parsers.has_parser then
        parsers.has_parser = function(lang)
          lang = lang or vim.treesitter.language.get_lang(vim.bo.filetype) or ''
          return pcall(vim.treesitter.language.add, lang)
        end
      end
      if not parsers.get_parser then
        parsers.get_parser = function(bufnr, lang)
          -- nvim 0.12: get_parser now returns (nil, err) instead of throwing.
          -- Telescope's previewer passes the result straight into
          -- vim.treesitter.highlighter.new(), which then crashes with
          -- `attempt to index local 'tree' (a nil value)` at highlighter.lua:95.
          -- Restore the old "throw on failure" contract so callers can't hit that.
          local parser, err = vim.treesitter.get_parser(bufnr, lang)
          if not parser then
            error(err or ('no treesitter parser for buffer ' .. tostring(bufnr)))
          end
          return parser
        end
      end
    end
    apply_parsers_shim()
    vim.api.nvim_create_autocmd('User', {
      pattern = 'TSUpdate',
      callback = apply_parsers_shim,
    })

    -- nvim-treesitter.configs is gone on main; provide a stub so plugins that
    -- call configs.is_enabled('highlight', ...) get a sensible answer.
    if not package.loaded['nvim-treesitter.configs'] then
      package.loaded['nvim-treesitter.configs'] = {
        is_enabled = function(mod, lang, bufnr)
          if mod ~= 'highlight' then
            return false
          end
          bufnr = bufnr or 0
          lang = lang or vim.treesitter.language.get_lang(vim.bo[bufnr].filetype) or ''
          if lang == '' then
            return false
          end
          if not pcall(vim.treesitter.language.add, lang) then
            return false
          end
          -- Also confirm a parser can actually be built for this buffer.
          -- Telescope's previewer calls is_enabled and then immediately calls
          -- get_parser; on nvim 0.12 that can return nil mid-keystroke, which
          -- then crashes vim.treesitter.highlighter.new(nil).
          local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
          return ok and parser ~= nil
        end,
        get_module = function(mod)
          if mod == 'highlight' then
            return { additional_vim_regex_highlighting = false }
          end
          return nil
        end,
        setup = function() end,
      }
    end

    require('nvim-treesitter').setup {}

    -- main branch dropped `ensure_installed` / `auto_install` from setup().
    -- Install any missing parsers ourselves by checking the runtime path.
    local ensure_installed = require 'parsers'
    local missing = {}
    for _, lang in ipairs(ensure_installed) do
      if #vim.api.nvim_get_runtime_file('parser/' .. lang .. '.so', false) == 0 then
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
