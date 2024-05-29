return {
  'smoka7/multicursors.nvim',
  event = 'VeryLazy',
  dependencies = {
    'smoka7/hydra.nvim',
  },
  opts = {},
  generate_hints = {
    normal = false,
    insert = false,
    extend = false,
  },
  cmd = { 'MCstart', 'MCvisual', 'MCclear', 'MCpattern', 'MCvisualPattern', 'MCunderCursor' },
  keys = {
    {
      mode = { 'v', 'n' },
      '<Leader>m',
      '<cmd>MCstart<cr>',
      desc = 'Create a selection for selected text or word under the cursor',
    },
  },
}
