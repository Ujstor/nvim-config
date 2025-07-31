return { -- Useful plugin to show you pending keybinds.
  'folke/which-key.nvim',
  event = 'VeryLazy', -- Sets the loading event to 'VeryLazy'
  config = function() -- This is the function that runs, AFTER loading
    require('which-key').setup {
      notify = false,
    }

    -- Document existing key chains
    require('which-key').register {
      { '<leader>c', group = '[C]ode' },
      { '<leader>c_', hidden = true },
      { '<leader>d', group = '[D]ocument' },
      { '<leader>d_', hidden = true },
      { '<leader>r', group = '[R]ename' },
      { '<leader>r_', hidden = true },
      { '<leader>s', group = '[S]earch' },
      { '<leader>s_', hidden = true },
      { '<leader>w', group = '[W]orkspace' },
      { '<leader>w_', hidden = true },
      { '<leader>m', group = '[M]arkdown' },
      { '<leader>m_', hidden = true },
      { '<leader>u', desc = '[U]ndotree toggle' },
      { '<leader>cc', desc = '[C]opilot [C]hat toggle' },
      { '<leader>co', desc = '[C]opilot [O]pen' },
      { '<leader>ccr', desc = '[C]opilot [C]hat [R]eset' },
      { '<leader>cs', desc = '[C]opilot [S]top' },
      { '<leader>cd', desc = '[C]opilot [D]isable' },
      { '<leader>ce', desc = '[C]opilot [E]nable' },
    }
  end,
}
