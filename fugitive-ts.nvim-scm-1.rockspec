rockspec_format = '3.0'
package = 'fugitive-ts.nvim'
version = 'scm-1'

source = {
  url = 'git+https://github.com/barrettruth/fugitive-ts.nvim.git',
}

description = {
  summary = 'Treesitter syntax highlighting for vim-fugitive',
  homepage = 'https://github.com/barrettruth/fugitive-ts.nvim',
  license = 'MIT',
}

dependencies = {
  'lua >= 5.1',
}

test_dependencies = {
  'nlua',
  'busted >= 2.1.1',
}

test = {
  type = 'busted',
}

build = {
  type = 'builtin',
}
