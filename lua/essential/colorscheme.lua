return { -- You can easily change to a different colorscheme.
  -- Change the name of the colorscheme plugin below, and then
  -- change the command in the config to whatever the name of that colorscheme is
  --
  -- If you want to see what colorschemes are already installed, you can use `:Telescope colorscheme`
  -- Load the colorscheme here
  'alexvzyl/nordic.nvim',
  lazy = false,
  priority = 1000,
  config = function()
    require('nordic').load()
    vim.cmd.colorscheme 'nordic'
    vim.cmd [[highlight EndOfBuffer guibg=bg guifg=bg]]
    -- You can configure highlights by doing something like
    vim.cmd.hi 'Comment gui=none'
  end,
}
