local M = {}

function M.check()
  vim.health.start('diffs.nvim')

  if vim.fn.has('nvim-0.9.0') == 1 then
    vim.health.ok('Neovim 0.9.0+ detected')
  else
    vim.health.error('diffs.nvim requires Neovim 0.9.0+')
  end

  local fugitive_loaded = vim.fn.exists(':Git') == 2
  if fugitive_loaded then
    vim.health.ok('vim-fugitive detected')
  else
    vim.health.warn('vim-fugitive not detected (required for unified diff highlighting)')
  end

  local lib = require('diffs.lib')
  if lib.has_lib() then
    vim.health.ok('libvscode_diff found at ' .. lib.lib_path())
  else
    vim.health.info('libvscode_diff not found (optional, using native vim.diff fallback)')
  end
end

return M
