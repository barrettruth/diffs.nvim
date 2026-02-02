if vim.g.loaded_fugitive_ts then
  return
end
vim.g.loaded_fugitive_ts = 1

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'fugitive',
  callback = function(args)
    require('fugitive-ts').attach(args.buf)
  end,
})
