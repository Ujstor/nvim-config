return {
  'MeanderingProgrammer/render-markdown.nvim',
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'nvim-tree/nvim-web-devicons',
  },
  ft = { 'markdown' },
  opts = {},
  keys = {
    { '<leader>me', '<cmd>RenderMarkdown enable<cr>', desc = '[M]arkdown [E]nable' },
    { '<leader>md', '<cmd>RenderMarkdown disable<cr>', desc = '[M]arkdown [D]isable' },
    { '<leader>mt', '<cmd>RenderMarkdown toggle<cr>', desc = '[M]arkdown [T]oggle' },
  },
}
