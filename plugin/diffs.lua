if vim.g.loaded_diffs then
  return
end

local config = require('diffs.config')
local integrations = require('diffs.integrations')
local user_config = config.new(vim.deepcopy(vim.g.diffs or {}))

vim.g.loaded_diffs = 1

local function get_runtime()
  local runtime = require('diffs.runtime')
  runtime.configure(user_config)
  return runtime
end

local function get_commands()
  return require('diffs.commands')
end

local function has_conflict_marker(bufnr)
  if vim.api.nvim_get_option_value('buftype', { buf = bufnr }) ~= '' then
    return false
  end
  return vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.search('^<<<<<<<', 'cnw') > 0
  end)
end

vim.api.nvim_create_user_command('Diff', function(opts)
  get_commands().diff_command(opts.args ~= '' and opts.args or nil, opts.smods.vertical)
end, {
  nargs = '*',
  bar = true,
  complete = function(...)
    return get_commands().complete_diff_command(...)
  end,
  desc = 'Show a current-file diff, a repository review with :Diff review, or two files with :Diff files',
})

local integration_config = user_config.integrations or {}

if integrations.is_enabled(integration_config.gitsigns) then
  if package.loaded.gitsigns then
    require('diffs.gitsigns').setup()
  else
    vim.api.nvim_create_autocmd('User', {
      pattern = 'GitAttach',
      once = true,
      callback = function()
        require('diffs.gitsigns').setup()
      end,
    })
  end
end

if integrations.is_enabled(integration_config.telescope) then
  require('diffs.telescope').setup(function(bufnr)
    get_runtime().attach(bufnr)
  end)
end

vim.api.nvim_create_autocmd('FileType', {
  pattern = config.compute_filetypes(user_config),
  callback = function(args)
    local runtime = get_runtime()
    runtime.attach(args.buf)

    if args.match == 'fugitive' then
      local fugitive_config = runtime.get_fugitive_config()
      if fugitive_config == true then
        require('diffs.fugitive').setup_keymaps(args.buf)
      end
    end
  end,
})

vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = 'diffs://*',
  callback = function(args)
    vim.cmd(
      ('lockmarks lua require("diffs.commands").read_buffer(%d, { quickfix = %s })'):format(
        args.buf,
        tostring(vim.b[args.buf].diffs_source ~= nil)
      )
    )
  end,
})

vim.api.nvim_create_autocmd('BufReadPost', {
  callback = function(args)
    local conflict_config = user_config.conflict
    if not conflict_config.enabled or not has_conflict_marker(args.buf) then
      return
    end
    local runtime = get_runtime()
    conflict_config = runtime.get_conflict_config()
    require('diffs.conflict').attach(args.buf, conflict_config)
  end,
})

vim.api.nvim_create_autocmd('OptionSet', {
  pattern = 'diff',
  callback = function()
    local runtime = get_runtime()
    if vim.wo.diff then
      runtime.attach_diff()
    else
      runtime.detach_diff()
    end
  end,
})

vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    if vim.wo.diff then
      get_runtime().attach_diff()
    end
  end,
})

vim.api.nvim_create_autocmd('OptionSet', {
  pattern = 'diffopt',
  callback = function()
    require('diffs.commands').on_diffopt_changed()
  end,
})

vim.keymap.set('n', '<Plug>(diffs-diff)', function()
  get_commands().diff(nil, false)
end, { desc = 'Unified diff (horizontal)' })
vim.keymap.set('n', '<Plug>(diffs-diff-vertical)', function()
  get_commands().diff(nil, true)
end, { desc = 'Unified diff (vertical)' })
vim.keymap.set('n', '<Plug>(diffs-diff-open-source)', function()
  require('diffs.hunks').open_source(vim.api.nvim_get_current_buf())
end, { desc = 'Open source file from generated diff' })
vim.keymap.set('n', '<Plug>(diffs-review-open-split)', function()
  get_commands().review_split()
end, { desc = 'Open review file in split diff' })
vim.keymap.set('n', '<Plug>(diffs-review-toggle-layout)', function()
  get_commands().review_toggle_layout()
end, { desc = 'Toggle review layout' })
vim.keymap.set('n', '<Plug>(diffs-review-next-file)', function()
  for _ = 1, vim.v.count1 do
    get_commands().review_next_file()
  end
end, { desc = 'Next file in review split' })
vim.keymap.set('n', '<Plug>(diffs-review-prev-file)', function()
  for _ = 1, vim.v.count1 do
    get_commands().review_prev_file()
  end
end, { desc = 'Previous file in review split' })
vim.keymap.set('n', '<Plug>(diffs-review-select-file)', function()
  get_commands().select_review_file()
end, { desc = 'Pick a file in the review split' })
vim.keymap.set('n', '<Plug>(diffs-refresh)', function()
  get_commands().refresh()
end, { desc = 'Re-render the current diff buffer' })

local function conflict_action(fn)
  local bufnr = vim.api.nvim_get_current_buf()
  local runtime = get_runtime()
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
  local runtime = get_runtime()
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
