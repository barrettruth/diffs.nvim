vim.cmd([[set runtimepath=$VIMRUNTIME]])

local root = vim.fn.fnamemodify('/tmp/diffs-minimal', ':p')
vim.opt.packpath = { root }
vim.env.XDG_CONFIG_HOME = root
vim.env.XDG_DATA_HOME = root
vim.env.XDG_STATE_HOME = root
vim.env.XDG_CACHE_HOME = root

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
    'barrettruth/midnight.nvim',
    lazy = false,
    config = function()
      vim.cmd.colorscheme('midnight')
    end,
  },
  { 'tpope/vim-fugitive' },
  { 'NeogitOrg/neogit', dependencies = { 'nvim-lua/plenary.nvim' } },
  { 'lewis6991/gitsigns.nvim', config = true },
  { 'rhysd/committia.vim' },
  { 'nvim-telescope/telescope.nvim', dependencies = { 'nvim-lua/plenary.nvim' } },
  {
    'barrettruth/diffs.nvim',
    init = function()
      vim.g.diffs = {
        debug = '/tmp/diffs.log',
        integrations = {
          fugitive = true,
          neogit = true,
          gitsigns = true,
          committia = true,
          telescope = true,
        },
      }
    end,
  },
}, { root = root .. '/plugins' })
