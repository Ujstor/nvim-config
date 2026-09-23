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

    -- Parsers are compiled on this host by `tree-sitter build`, which honours $CC.
    -- Build them with clang when it is installed: under the -Wall tree-sitter
    -- passes, gcc 12 (Debian 12's) spends over 25 minutes and ~2 GB on the
    -- gitcommit parser, which clang builds in 7 s, and clang is faster than
    -- gcc 13/14 on it too. Only the `tree-sitter build` processes get CC=clang,
    -- so :terminal and :make keep your compiler, and a $CC you set wins.
    if (vim.env.CC or '') == '' and vim.fn.executable 'clang' == 1 then
      local system = vim.system
      ---@diagnostic disable-next-line: duplicate-set-field
      vim.system = function(cmd, opts, on_exit)
        if type(opts) == 'function' then
          opts, on_exit = nil, opts
        end
        if type(cmd) == 'table' and type(cmd[1]) == 'string' and cmd[2] == 'build' and vim.fs.basename(cmd[1]) == 'tree-sitter' then
          opts = vim.deepcopy(opts or {})
          opts.env = vim.tbl_extend('keep', opts.env or {}, { CC = 'clang' })
        end
        return system(cmd, opts, on_exit)
      end
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

    -- main branch dropped `ensure_installed` / `auto_install` from setup(), so
    -- missing parsers are installed here, and only in an nvim with a UI. A
    -- headless one (install.sh's bootstrap, a scripted `+Lazy! sync +qa`) quits
    -- long before a build ends: an install of its own then waited on these same
    -- languages, gave up after nvim-treesitter's 60 s per-language timeout
    -- without saying so, and the orphaned compilers ran on after nvim was gone.
    if #vim.api.nvim_list_uis() == 0 then
      return
    end

    -- Names absent from nvim-treesitter's registry are skipped: they can never
    -- install, so they'd otherwise be re-attempted on every startup and log
    -- "skipping unsupported language: <name>" each time.
    local registry = require 'nvim-treesitter.parsers'
    local function installed(lang)
      return #vim.api.nvim_get_runtime_file('parser/' .. lang .. '.so', false) > 0
    end

    -- A language that failed to build is left alone for a day rather than
    -- retried at every start: where a build cannot succeed (no compiler, no
    -- tree-sitter CLI), each launch otherwise restarted the same doomed
    -- compiles and repeated the same errors. :TSInstall retries one now.
    local memo = vim.fn.stdpath 'state' .. '/treesitter-failed'
    local recent = {}
    local st = vim.uv.fs_stat(memo)
    if st and os.time() - st.mtime.sec < 24 * 3600 then
      for _, lang in ipairs(vim.fn.readfile(memo)) do
        recent[lang] = true
      end
    end

    local missing, held = {}, {}
    for _, lang in ipairs(require 'parsers') do
      if registry[lang] ~= nil and not installed(lang) then
        table.insert(recent[lang] and held or missing, lang)
      end
    end
    local function warn(msg)
      vim.schedule(function()
        vim.notify('treesitter: ' .. msg, vim.log.levels.WARN)
      end)
    end
    if #held > 0 then
      local names = table.concat(vim.list_slice(held, 1, 2), ', ') .. (#held > 2 and (' +' .. (#held - 2)) or '')
      warn(names .. ' failed to build recently; :TSInstall retries')
    end
    if #missing == 0 then
      return
    end
    -- Without the CLI every language fails the same way, one error each.
    if vim.fn.executable 'tree-sitter' == 0 then
      warn(#missing .. ' parser(s) missing, and no tree-sitter CLI on PATH to build them')
      return
    end

    -- At most four compilers at once, fewer on a smaller machine. The default is
    -- 100, which on a 1 GiB box ended in an OOM-killed cc1. `force`, because
    -- nvim-treesitter counts a language whose queries are present as installed
    -- and skips it, and every language here is one with no parser at all.
    local jobs = math.min(4, vim.uv.available_parallelism())
    require('nvim-treesitter').install(missing, { max_jobs = jobs, force = true }):await(function()
      vim.schedule(function()
        local failed = vim.tbl_filter(function(lang)
          return not installed(lang)
        end, missing)
        if #failed > 0 then
          vim.fn.mkdir(vim.fs.dirname(memo), 'p')
          vim.fn.writefile(vim.list_extend(failed, held), memo)
        elseif #held == 0 then
          os.remove(memo)
        end
      end)
    end)
  end,
}
