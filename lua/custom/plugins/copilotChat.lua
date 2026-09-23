return {
  {
    'CopilotC-Nvim/CopilotChat.nvim',
    branch = 'main',
    -- No copilot.lua here: it was loaded but never set up, so it sat beside
    -- copilot.vim (custom/plugins/copilot.lua) as a second, broken Copilot
    -- client. CopilotChat reads the token that copilot.vim's :Copilot setup
    -- writes to ~/.config/github-copilot.
    dependencies = {
      { 'nvim-lua/plenary.nvim' }, -- for curl, log wrapper
    },
    build = 'make tiktoken', -- Only on MacOS or Linux
    -- No `debug = true`: it logs every request in full, the GitHub token in its
    -- Authorization header included, to ~/.local/state/nvim/CopilotChat.log.
    opts = {},
    -- See Commands section for default commands if you want to lazy load on them
  },
}
