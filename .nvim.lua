vim.pack.add({
  'https://github.com/nvimdev/guard.nvim',
  'https://github.com/nvimdev/guard-collection',
}, { confirm = false, load = true })

local ft = require('guard.filetype')

ft('lua'):fmt('stylua'):lint('selene')
ft('json,jsonc'):fmt('biome')
ft('nix'):fmt({
  cmd = 'nix',
  args = { 'fmt', '--', '--stdin' },
  stdin = true,
  fname = true,
})
