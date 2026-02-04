if vim.g.loaded_diffs then
  return
end
vim.g.loaded_diffs = 1

require('diffs.commands').setup()

vim.api.nvim_create_autocmd('FileType', {
  pattern = { 'fugitive', 'git' },
  callback = function(args)
    local diffs = require('diffs')
    if args.match == 'git' and not diffs.is_fugitive_buffer(args.buf) then
      return
    end
    diffs.attach(args.buf)
  end,
})

vim.api.nvim_create_autocmd('OptionSet', {
  pattern = 'diff',
  callback = function()
    if vim.wo.diff then
      require('diffs').attach_diff()
    else
      require('diffs').detach_diff()
    end
  end,
})
