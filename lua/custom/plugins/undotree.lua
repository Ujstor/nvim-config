return {
  'jiaoshijie/undotree',
  dependencies = 'nvim-lua/plenary.nvim',
  keys = { -- load the plugin only when using it's keybinding:
    { '<leader>u', "<cmd>lua require('undotree').toggle()<cr>" },
  },
  -- Under `opts`: lazy.nvim hands only `opts` to setup(), so as top-level keys of
  -- the spec none of these ever reached the plugin.
  opts = {
    float_diff = true, -- using float window previews diff, set this `true` will disable layout option
    layout = 'left_bottom', -- "left_bottom", "left_left_bottom"
    position = 'left', -- "right", "bottom"
    ignore_filetype = { 'undotree', 'undotreeDiff', 'qf', 'TelescopePrompt', 'spectre_panel', 'tsplayground' },
    keymaps = { -- action = key; the older key = action form is deprecated
      move_next = 'j',
      move_prev = 'k',
      move2parent = 'gj',
      move_change_next = 'J',
      move_change_prev = 'K',
      action_enter = '<cr>',
      enter_diffbuf = 'p',
      quit = 'q',
    },
  },
}
