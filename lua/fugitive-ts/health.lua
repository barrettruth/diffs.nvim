local M = {}

function M.check()
  vim.health.start('fugitive-ts.nvim')

  if vim.fn.has('nvim-0.9.0') == 1 then
    vim.health.ok('Neovim 0.9.0+ detected')
  else
    vim.health.error('fugitive-ts.nvim requires Neovim 0.9.0+')
  end

  local fugitive_loaded = vim.fn.exists(':Git') == 2
  if fugitive_loaded then
    vim.health.ok('vim-fugitive detected')
  else
    vim.health.warn('vim-fugitive not detected (required for this plugin to be useful)')
  end
end

return M
