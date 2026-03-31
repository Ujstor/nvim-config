return {
  'MeanderingProgrammer/render-markdown.nvim',
  dependencies = {
    'nvim-treesitter/nvim-treesitter',
    'nvim-tree/nvim-web-devicons',
  },
  -- Disabled until nvim-treesitter main branch is installed (:Lazy sync + :TSUpdate)
  -- ft = { 'markdown' } triggers loading which crashes with nvim-treesitter master on Neovim 0.12
  enabled = false,
}
