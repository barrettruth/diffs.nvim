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

    if args.match == 'fugitive' then
      local fugitive_config = diffs.get_fugitive_config()
      if fugitive_config.horizontal or fugitive_config.vertical then
        require('diffs.fugitive').setup_keymaps(args.buf, fugitive_config)
      end
    end
  end,
})

vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = 'diffs://*',
  callback = function(args)
    require('diffs.commands').read_buffer(args.buf)
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

local cmds = require('diffs.commands')
vim.keymap.set('n', '<Plug>(diffs-gdiff)', function()
  cmds.gdiff(nil, false)
end, { desc = 'Unified diff (horizontal)' })
vim.keymap.set('n', '<Plug>(diffs-gvdiff)', function()
  cmds.gdiff(nil, true)
end, { desc = 'Unified diff (vertical)' })
