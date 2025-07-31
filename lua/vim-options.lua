vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- See `:help vim.opt`
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.mouse = 'a'
vim.opt.showmode = false
vim.opt.clipboard = 'unnamedplus'
vim.opt.breakindent = true
vim.opt.undofile = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.signcolumn = 'yes'
vim.opt.updatetime = 250
vim.opt.timeoutlen = 300
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.list = true
vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }
vim.opt.inccommand = 'split'
vim.opt.cursorline = true
vim.opt.scrolloff = 10

--  See `:help vim.keymap.set()`

-- custom remap
vim.keymap.set('n', '<C-d>', '<C-d>zz')
vim.keymap.set('n', '<C-u>', '<C-u>zz')
vim.keymap.set('v', '<leader>p', '"_dP', { desc = 'd into _reg and P for reuse previous y' })
vim.keymap.set('i', '<C-c>', '<Esc>')

-- Set highlight on search, but clear on pressing <Esc> in normal mode
vim.opt.hlsearch = true
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Diagnostic keymaps
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev, { desc = 'Go to previous [D]iagnostic message' })
vim.keymap.set('n', ']d', vim.diagnostic.goto_next, { desc = 'Go to next [D]iagnostic message' })
vim.keymap.set('n', '<leader>ed', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- TIP: Disable arrow keys in normal mode
vim.keymap.set('n', '<left>', '<cmd>echo "Use h to move!!"<CR>')
vim.keymap.set('n', '<right>', '<cmd>echo "Use l to move!!"<CR>')
vim.keymap.set('n', '<up>', '<cmd>echo "Use k to move!!"<CR>')
vim.keymap.set('n', '<down>', '<cmd>echo "Use j to move!!"<CR>')

--  See `:help wincmd` for a list of all window commands
-- Note: C-h/j/k/l handled by vim-tmux-navigator plugin

vim.keymap.set('n', '<Leader>e', '<Cmd>Neotree toggle<CR>', { desc = 'Neotree file explorer' })

-- Map keys for opening/closing Copilot Chat window
vim.keymap.set('n', '<leader>cc', ':CopilotChatToggle<CR>', { desc = '[C]opilot [C]hat toggle' })
vim.keymap.set('n', '<leader>co', ':CopilotChatOpen<CR>', { desc = '[C]opilot [O]pen' })
vim.keymap.set('n', '<leader>ccr', ':CopilotChatReset<CR>', { desc = '[C]opilot [C]hat [R]eset' })
vim.keymap.set('n', '<leader>cs', ':CopilotChatStop<CR>', { desc = '[C]opilot [S]top' })
