if vim.g.loaded_diffs then
  return
end
vim.g.loaded_diffs = 1

require('diffs.commands').setup()
local config = require('diffs.config')
local runtime = require('diffs.runtime')

local function get_raw_integration(key)
  local user = vim.g.diffs or {}
  local intg = user.integrations or {}
  local v = intg[key]
  if v ~= nil then
    return v
  end
  return user[key]
end

local gs_cfg = get_raw_integration('gitsigns')
if gs_cfg == true or type(gs_cfg) == 'table' then
  if not require('diffs.gitsigns').setup() then
    vim.api.nvim_create_autocmd('User', {
      pattern = 'GitAttach',
      once = true,
      callback = function()
        require('diffs.gitsigns').setup()
      end,
    })
  end
end

local tel_cfg = get_raw_integration('telescope')
if tel_cfg == true or type(tel_cfg) == 'table' then
  vim.api.nvim_create_autocmd('User', {
    pattern = 'TelescopePreviewerLoaded',
    callback = function()
      runtime.attach(vim.api.nvim_get_current_buf())
    end,
  })
end

vim.api.nvim_create_autocmd('FileType', {
  pattern = config.compute_filetypes(vim.g.diffs or {}),
  callback = function(args)
    runtime.attach(args.buf)

    if args.match == 'fugitive' then
      local fugitive_config = runtime.get_fugitive_config()
      if fugitive_config and (fugitive_config.horizontal or fugitive_config.vertical) then
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

vim.api.nvim_create_autocmd('BufReadPost', {
  callback = function(args)
    local conflict_config = runtime.get_conflict_config()
    if conflict_config.enabled then
      require('diffs.conflict').attach(args.buf, conflict_config)
    end
  end,
})

vim.api.nvim_create_autocmd('OptionSet', {
  pattern = 'diff',
  callback = function()
    if vim.wo.diff then
      runtime.attach_diff()
    else
      runtime.detach_diff()
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

local function conflict_action(fn)
  local bufnr = vim.api.nvim_get_current_buf()
  local conflict_config = runtime.get_conflict_config()
  fn(bufnr, conflict_config)
end

vim.keymap.set('n', '<Plug>(diffs-conflict-ours)', function()
  conflict_action(require('diffs.conflict').resolve_ours)
end, { desc = 'Accept current (ours) change' })
vim.keymap.set('n', '<Plug>(diffs-conflict-theirs)', function()
  conflict_action(require('diffs.conflict').resolve_theirs)
end, { desc = 'Accept incoming (theirs) change' })
vim.keymap.set('n', '<Plug>(diffs-conflict-both)', function()
  conflict_action(require('diffs.conflict').resolve_both)
end, { desc = 'Accept both changes' })
vim.keymap.set('n', '<Plug>(diffs-conflict-none)', function()
  conflict_action(require('diffs.conflict').resolve_none)
end, { desc = 'Reject both changes' })
vim.keymap.set('n', '<Plug>(diffs-conflict-next)', function()
  require('diffs.conflict').goto_next(vim.api.nvim_get_current_buf())
end, { desc = 'Jump to next conflict' })
vim.keymap.set('n', '<Plug>(diffs-conflict-prev)', function()
  require('diffs.conflict').goto_prev(vim.api.nvim_get_current_buf())
end, { desc = 'Jump to previous conflict' })

local function merge_action(fn)
  local bufnr = vim.api.nvim_get_current_buf()
  local conflict_config = runtime.get_conflict_config()
  fn(bufnr, conflict_config)
end

vim.keymap.set('n', '<Plug>(diffs-merge-ours)', function()
  merge_action(require('diffs.merge').resolve_ours)
end, { desc = 'Accept ours in merge diff' })
vim.keymap.set('n', '<Plug>(diffs-merge-theirs)', function()
  merge_action(require('diffs.merge').resolve_theirs)
end, { desc = 'Accept theirs in merge diff' })
vim.keymap.set('n', '<Plug>(diffs-merge-both)', function()
  merge_action(require('diffs.merge').resolve_both)
end, { desc = 'Accept both in merge diff' })
vim.keymap.set('n', '<Plug>(diffs-merge-none)', function()
  merge_action(require('diffs.merge').resolve_none)
end, { desc = 'Reject both in merge diff' })
vim.keymap.set('n', '<Plug>(diffs-merge-next)', function()
  require('diffs.merge').goto_next(vim.api.nvim_get_current_buf())
end, { desc = 'Jump to next conflict hunk' })
vim.keymap.set('n', '<Plug>(diffs-merge-prev)', function()
  require('diffs.merge').goto_prev(vim.api.nvim_get_current_buf())
end, { desc = 'Jump to previous conflict hunk' })
