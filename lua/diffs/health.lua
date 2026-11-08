local M = {}

function M.check()
  vim.health.start('diffs.nvim')

  if vim.fn.has('nvim-0.12.0') == 1 then
    vim.health.ok('Neovim 0.12.0+ detected')
  else
    vim.health.error('diffs.nvim requires Neovim 0.12.0+')
  end

  if pcall(vim.treesitter.language.add, 'diff') then
    vim.health.ok('Treesitter diff parser available')
  else
    vim.health.info('Treesitter diff parser unavailable. Diffs uses its Lua parser.')
  end
end

return M
