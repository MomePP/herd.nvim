-- Minimal init for plenary-busted runs. plenary lives in pack/core/opt.
vim.cmd('packadd plenary.nvim')
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.swapfile = false
