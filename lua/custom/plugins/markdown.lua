return {
  'MeanderingProgrammer/render-markdown.nvim',
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'nvim-tree/nvim-web-devicons',
  },
  ft = { 'markdown' }, -- Only load for markdown files (optional optimization)
  ---@module 'render-markdown'
  ---@type render.md.UserConfig
  opts = {
    -- Disable by default
    enabled = false,
  },
  keys = {
    {
      '<leader>mr',
      function()
        require('render-markdown').toggle()
      end,
      desc = 'Toggle [M]arkdown [R]endering',
      ft = 'markdown',
    },
    {
      '<leader>me',
      function()
        require('render-markdown').enable()
      end,
      desc = '[M]arkdown [E]nable rendering',
      ft = 'markdown',
    },
    {
      '<leader>md',
      function()
        require('render-markdown').disable()
      end,
      desc = '[M]arkdown [D]isable rendering',
      ft = 'markdown',
    },
  },
}
