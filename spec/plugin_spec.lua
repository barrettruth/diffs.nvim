require('spec.helpers')

describe('plugin bootstrap', function()
  local function run_child_result(init_lines, after_lines)
    local tmpdir = vim.fn.resolve(vim.fn.tempname())
    assert.are.equal(1, vim.fn.mkdir(tmpdir, 'p'))
    local init_file = tmpdir .. '/init.lua'
    local after_file = tmpdir .. '/after.lua'
    vim.fn.writefile(init_lines, init_file)
    vim.fn.writefile(after_lines or {}, after_file)

    local output = vim.fn.system({
      vim.v.progpath,
      '--headless',
      '--clean',
      '-u',
      init_file,
      '+luafile ' .. after_file,
      '+qa',
    })
    local shell_error = vim.v.shell_error
    vim.fn.delete(tmpdir, 'rf')
    return shell_error, output
  end

  local function run_child(init_lines, after_lines)
    local shell_error, output = run_child_result(init_lines, after_lines)
    assert.are.equal(0, shell_error, output)
    return output
  end

  it('loads supported config during plugin startup', function()
    local init_lines = {
      '_G.diffs_notifications = {}',
      'vim.notify = function(message, level)',
      '_G.diffs_notifications[#_G.diffs_notifications + 1] = { message = message, level = level }',
      'end',
      'vim.g.diffs = { view = { prefix = false }, highlights = { background = false }, conflict = { show_virtual_text = false }, integrations = { fugitive = true, neogit = true, neojj = true, gitsigns = true, committia = true, telescope = true } }',
      ('vim.opt.runtimepath:prepend(%s)'):format(vim.inspect(vim.fn.getcwd())),
    }

    local after_lines = {
      "print('loaded=' .. tostring(vim.g.loaded_diffs))",
      "print('notifications=' .. #(_G.diffs_notifications or {}))",
      "local runtime = require('diffs.runtime')",
      'runtime.attach(0)',
      "print('after_attach_notifications=' .. #(_G.diffs_notifications or {}))",
      'local runtime_config = runtime._test.get_config()',
      'local highlight_opts = runtime.get_highlight_opts()',
      "print('runtime_view_prefix=' .. tostring(runtime_config.view.prefix))",
      "print('runtime_fugitive=' .. tostring(runtime_config.integrations.fugitive))",
      "print('runtime_neogit=' .. tostring(runtime_config.integrations.neogit))",
      "print('runtime_neojj=' .. tostring(runtime_config.integrations.neojj))",
      "print('runtime_gitsigns=' .. tostring(runtime_config.integrations.gitsigns))",
      "print('runtime_committia=' .. tostring(runtime_config.integrations.committia))",
      "print('runtime_telescope=' .. tostring(runtime_config.integrations.telescope))",
      "print('runtime_background=' .. tostring(runtime_config.highlights.background))",
      "print('runtime_show_virtual_text=' .. tostring(runtime_config.conflict.show_virtual_text))",
      "print('runtime_config_priorities=' .. tostring(runtime_config.highlights.priorities))",
      "print('highlight_priority_clear=' .. tostring(highlight_opts.highlights.priorities.clear))",
      "print('highlight_priority_syntax=' .. tostring(highlight_opts.highlights.priorities.syntax))",
      "print('highlight_priority_line_bg=' .. tostring(highlight_opts.highlights.priorities.line_bg))",
      "print('highlight_priority_char_bg=' .. tostring(highlight_opts.highlights.priorities.char_bg))",
      'local has_fugitive = false',
      'local has_neogit = false',
      'local has_neojj = false',
      'local has_telescope = false',
      "for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'FileType' })) do",
      "if autocmd.pattern == 'fugitive' then has_fugitive = true end",
      "if autocmd.pattern == 'NeogitStatus' then has_neogit = true end",
      "if autocmd.pattern == 'NeojjStatus' then has_neojj = true end",
      'end',
      "for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'User' })) do",
      "if autocmd.pattern == 'TelescopePreviewerLoaded' then has_telescope = true end",
      'end',
      "print('has_fugitive_autocmd=' .. tostring(has_fugitive))",
      "print('has_neogit_autocmd=' .. tostring(has_neogit))",
      "print('has_neojj_autocmd=' .. tostring(has_neojj))",
      "print('has_telescope_autocmd=' .. tostring(has_telescope))",
    }

    local output = run_child(init_lines, after_lines)

    assert.matches('loaded=1', output, 1, true)
    assert.matches('notifications=0', output, 1, true)
    assert.matches('after_attach_notifications=0', output, 1, true)
    assert.matches('runtime_view_prefix=false', output, 1, true)
    assert.matches('runtime_fugitive=true', output, 1, true)
    assert.matches('runtime_neogit=true', output, 1, true)
    assert.matches('runtime_neojj=true', output, 1, true)
    assert.matches('runtime_gitsigns=true', output, 1, true)
    assert.matches('runtime_committia=true', output, 1, true)
    assert.matches('runtime_telescope=true', output, 1, true)
    assert.matches('runtime_background=false', output, 1, true)
    assert.matches('runtime_show_virtual_text=false', output, 1, true)
    assert.matches('runtime_config_priorities=nil', output, 1, true)
    assert.matches('highlight_priority_clear=198', output, 1, true)
    assert.matches('highlight_priority_syntax=199', output, 1, true)
    assert.matches('highlight_priority_line_bg=200', output, 1, true)
    assert.matches('highlight_priority_char_bg=201', output, 1, true)
    assert.matches('has_fugitive_autocmd=true', output, 1, true)
    assert.matches('has_neogit_autocmd=true', output, 1, true)
    assert.matches('has_neojj_autocmd=true', output, 1, true)
    assert.matches('has_telescope_autocmd=true', output, 1, true)
  end)

  it('rejects removed config during plugin startup', function()
    local init_lines = {
      'vim.g.diffs = { hide_prefix = true, highlights = { gutter = false, priorities = { syntax = 250 } }, conflict = { priority = 250 }, integrations = { fugitive = {} } }',
      ('vim.opt.runtimepath:prepend(%s)'):format(vim.inspect(vim.fn.getcwd())),
    }

    local shell_error, output = run_child_result(init_lines, {})

    assert.are.equal(0, shell_error)
    assert.matches('Error in ', output, 1, true)
    assert.matches('diffs: hide_prefix has been removed; use view.prefix', output, 1, true)
  end)

  it('navigates both review panes and preserves quickfix entries across reloads', function()
    local init_lines = {
      ('vim.opt.runtimepath:prepend(%s)'):format(vim.inspect(vim.fn.getcwd())),
      'vim.g.diffs = { integrations = { difftastic = false } }',
    }
    local after_lines = vim.split(
      [[
local repo = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(repo, 'p')
local function git(...)
  local output = vim.fn.systemlist({ 'git', '-C', repo, ... })
  assert(vim.v.shell_error == 0, table.concat(output, '\n'))
end
local ok, err = pcall(function()
  git('init', '-q')
  git('config', 'user.name', 'Test')
  git('config', 'user.email', 'test@example.com')
  for _, file in ipairs({ 'one.lua', 'three.lua', 'two.lua' }) do
    vim.fn.writefile({ 'old' }, repo .. '/' .. file)
  end
  git('add', '.')
  git('commit', '-qm', 'base')
  for _, file in ipairs({ 'one.lua', 'three.lua', 'two.lua' }) do
    vim.fn.writefile({ 'new' }, repo .. '/' .. file)
  end
  git('commit', '-qam', 'target')
  vim.cmd.cd(repo)
  vim.cmd('Diff review HEAD~1')
  local buf = vim.api.nvim_get_current_buf()
  local window_count = #vim.api.nvim_tabpage_list_wins(0)
  local statuscolumn = vim.wo.statuscolumn
  local before = vim.fn.getqflist({ id = 0, items = 0 })
  assert(#before.items == 3)
  vim.keymap.set('n', ']q', '<cmd>cnext<cr>')
  vim.keymap.set('n', '[q', '<cmd>cprevious<cr>')
  vim.cmd('normal gs')
  assert(not vim.api.nvim_buf_is_loaded(buf))
  local pair_wins = vim.tbl_filter(function(win)
    return require('diffs').review_current(vim.api.nvim_win_get_buf(win)) ~= nil
  end, vim.api.nvim_tabpage_list_wins(0))
  assert(#pair_wins == 2)
  local reads = 0
  local autocmd = vim.api.nvim_create_autocmd('BufReadCmd', {
    pattern = 'diffs://review:*',
    callback = function() reads = reads + 1 end,
  })
  local function check_pair(index)
    assert(#vim.api.nvim_tabpage_list_wins(0) == window_count + 1)
    for _, win in ipairs(pair_wins) do
      local pane = vim.api.nvim_win_get_buf(win)
      local current = require('diffs').review_current(pane)
      assert(current and current.index == index, vim.inspect(current))
      assert(vim.bo[pane].modifiable == false)
      assert(vim.wo[win].scrollbind and vim.wo[win].cursorbind)
    end
    assert(reads == 0)
    assert(vim.fn.getqflist({ id = 0 }).id == before.id)
  end
  check_pair(1)
  vim.cmd('normal ]q')
  check_pair(2)
  vim.api.nvim_set_current_win(pair_wins[1])
  vim.cmd('normal ]q')
  check_pair(3)
  vim.cmd('normal ]q')
  check_pair(1)
  vim.cmd('normal [q')
  check_pair(3)
  vim.cmd('normal 2[q')
  check_pair(1)
  vim.cmd('normal 2]q')
  check_pair(3)
  vim.api.nvim_del_autocmd(autocmd)
  vim.cmd('normal gs')
  assert(#vim.api.nvim_tabpage_list_wins(0) == window_count)
  buf = vim.api.nvim_get_current_buf()
  assert(vim.b[buf].diffs_review.layout == 'unified')
  before = vim.fn.getqflist({ id = 0, items = 0 })
  vim.cmd('normal gs')
  assert(require('diffs').review_current().index == 3)
  vim.cmd('normal q')
  local remaining_windows = #vim.api.nvim_tabpage_list_wins(0)
  vim.cmd('cc 2')
  local after = vim.fn.getqflist({ id = 0, idx = 0 })
  assert(after.id == before.id)
  assert(after.idx == 2)
  assert(vim.api.nvim_get_current_buf() == buf)
  assert(vim.api.nvim_win_get_cursor(0)[1] == before.items[2].lnum)
  assert(#vim.api.nvim_tabpage_list_wins(0) == remaining_windows)
  assert(not vim.wo.scrollbind)
  assert(not vim.wo.cursorbind)
  assert(vim.wo.statuscolumn == statuscolumn)
  vim.fn.writefile({ 'new file' }, repo .. '/four.lua')
  vim.cmd('edit')
  assert(#vim.fn.getqflist() == 4)
end)
vim.fn.delete(repo, 'rf')
assert(ok, err)
print('quickfix_reloaded=true')
]],
      '\n'
    )

    local output = run_child(init_lines, after_lines)
    assert.matches('quickfix_reloaded=true', output, 1, true)
  end)

  it('enhances native diff windows opened at startup with nvim -d', function()
    local tmpdir = vim.fn.resolve(vim.fn.tempname())
    assert.are.equal(1, vim.fn.mkdir(tmpdir, 'p'))
    local file_a = tmpdir .. '/a.txt'
    local file_b = tmpdir .. '/b.txt'
    vim.fn.writefile({ 'local x = 1', 'local y = 2' }, file_a)
    vim.fn.writefile({ 'local x = 1', 'local y = 3' }, file_b)

    local init_file = tmpdir .. '/init.lua'
    vim.fn.writefile({
      ('vim.opt.runtimepath:prepend(%s)'):format(vim.inspect(vim.fn.getcwd())),
    }, init_file)

    local check = table.concat({
      'lua vim.schedule(function()',
      'local parts = {}',
      'for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do',
      'if vim.wo[win].diff then parts[#parts + 1] = vim.wo[win].winhighlight end',
      'end',
      "print('DIFF_WINHL=' .. table.concat(parts, '||'))",
      "vim.cmd('qa!')",
      'end)',
    }, ' ')

    local output = vim.fn.system({
      vim.v.progpath,
      '--headless',
      '--clean',
      '-u',
      init_file,
      '-d',
      file_a,
      file_b,
      '-c',
      check,
    })
    vim.fn.delete(tmpdir, 'rf')

    assert.matches('DIFF_WINHL=', output, 1, true)
    assert.matches('DiffAdd:DiffsDiffAdd', output, 1, true)
  end)
end)
