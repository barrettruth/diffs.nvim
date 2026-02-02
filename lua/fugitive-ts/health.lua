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

  ---@type string[]
  local common_langs = { 'lua', 'python', 'javascript', 'typescript', 'rust', 'go', 'c', 'cpp' }
  ---@type string[]
  local available = {}
  ---@type string[]
  local missing = {}

  for _, lang in ipairs(common_langs) do
    local ok = pcall(vim.treesitter.language.inspect, lang)
    if ok then
      table.insert(available, lang)
    else
      table.insert(missing, lang)
    end
  end
end

return M
