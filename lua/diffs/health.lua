local M = {}

function M.check()
  vim.health.start('diffs.nvim')

  if vim.fn.has('nvim-0.12.0') == 1 then
    vim.health.ok('Neovim 0.12.0+ detected')
  else
    vim.health.error('diffs.nvim requires Neovim 0.12.0+')
  end

  local fugitive_loaded = vim.fn.exists(':Git') == 2
  if fugitive_loaded then
    vim.health.ok('vim-fugitive detected')
  else
    vim.health.warn('vim-fugitive not detected (required for unified diff highlighting)')
  end

  local difftastic = require('diffs.difftastic')
  if not difftastic.resolve().enabled then
    vim.health.info('difftastic not enabled (optional, set integrations.difftastic)')
  elseif difftastic.available() then
    vim.health.ok('difftastic (difft) found on PATH')
  else
    vim.health.warn('integrations.difftastic is enabled but difft was not found on PATH')
  end
end

return M
