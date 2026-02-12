vim.cmd([[set runtimepath=$VIMRUNTIME]])
vim.opt.runtimepath:append('.')
vim.opt.runtimepath:append(vim.fn.stdpath('data') .. '/site')
vim.opt.packpath = {}
vim.opt.loadplugins = false
vim.cmd('filetype on')
