return {
  'smoka7/multicursors.nvim',
  event = 'VeryLazy',
  dependencies = {
    'smoka7/hydra.nvim',
  },
  opts = {},
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
-- Key	Description
-- <Esc>	Returns to multicursor normal mode
-- c	Prompts user for a motion and performs it
-- o	Toggles the anchor side
-- O	Toggles the anchor side
-- w	[count] word forward
-- e	[count] forward to end of word
-- b	[count] word backward
-- h	[count] char left
-- j	[count] char down
-- k	[count] char up
-- l	[count] char right
-- t	Extends the selection to the parent of the selected node
-- r	Shrinks the selection to the first child of the selected node
-- y	Shrinks the selection to the last child of the selected node
-- u	Undo Last selections extend or shrink
-- $	[count] to end of line
-- ^	To the first non-blank character of the line
