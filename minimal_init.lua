vim.cmd([[set runtimepath=$VIMRUNTIME]])
vim.o.background = 'dark'
vim.o.number = true
vim.o.relativenumber = true

local root = vim.fn.fnamemodify('/tmp/diffs-harivansh-repro', ':p')
vim.opt.packpath = { root }
vim.env.XDG_CONFIG_HOME = root
vim.env.XDG_DATA_HOME = root
vim.env.XDG_STATE_HOME = root
vim.env.XDG_CACHE_HOME = root

vim.opt.rtp:prepend(vim.fn.expand('~/dev/diffs.nvim'))

local lazypath = root .. '/lazy.nvim'
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    'git',
    'clone',
    '--filter=blob:none',
    '--branch=stable',
    'https://github.com/folke/lazy.nvim.git',
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require('lazy').setup({
  {
    dir = vim.fn.expand('~/dev/midnight.nvim'),
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme('midnight')
    end,
  },
  { 'tpope/vim-fugitive' },
  {
    dir = vim.fn.expand('~/dev/diffs.nvim'),
    init = function()
      vim.g.diffs = {
        integrations = {
          fugitive = {
            enabled = true,
            horizontal = false,
            vertical = false,
          },
        },
        hide_prefix = false,
        highlights = {
          gutter = true,
          intra = { enabled = true },
          overrides = {
            DiffsAdd = { bg = '#ff0000' },
            DiffsDelete = { bg = '#0000ff' },
          },
        },
      }
    end,
  },
}, { root = root .. '/plugins' })
