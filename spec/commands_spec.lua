local helpers = require('spec.helpers')

local commands = require('diffs.commands')
local diffspec = require('diffs.spec')
local generated = require('diffs.generated')
local git = require('diffs.git')
local rails = require('diffs.rails')
local runtime = require('diffs.runtime')
local split = require('diffs.split')

local saved_git = {}
local saved_runtime_attach
local saved_runtime_get_conflict_config
local saved_runtime_get_view_config
local saved_runtime_get_highlight_opts
local saved_schedule
local saved_systemlist
local saved_notify
local test_buffers = {}
local test_repos = {}

local function mock_repo_root(fn)
  saved_git.get_repo_root = git.get_repo_root
  git.get_repo_root = fn
end

local function mock_git_method(name, fn)
  saved_git[name] = git[name]
  git[name] = fn
end

local function mock_systemlist(fn)
  saved_systemlist = vim.fn.systemlist
  vim.fn.systemlist = function(cmd)
    local result, shell_error = fn(cmd)
    if shell_error and shell_error ~= 0 then
      saved_systemlist({ 'false' })
    else
      saved_systemlist({ 'true' })
    end
    return result
  end
end

local function mock_runtime_attach(fn)
  saved_runtime_attach = runtime.attach
  runtime.attach = fn
  saved_schedule = vim.schedule
  vim.schedule = function(callback)
    callback()
  end
end

local function mock_conflict_config(config)
  saved_runtime_get_conflict_config = runtime.get_conflict_config
  runtime.get_conflict_config = function()
    return config
  end
end

local function mock_view_config(config)
  saved_runtime_get_view_config = runtime.get_view_config
  runtime.get_view_config = function()
    return config
  end
end

local function mock_highlight_opts(mutate)
  saved_runtime_get_highlight_opts = runtime.get_highlight_opts
  local base = saved_runtime_get_highlight_opts()
  runtime.get_highlight_opts = function()
    local opts = vim.deepcopy(base)
    mutate(opts)
    return opts
  end
end

local function capture_notifications()
  local notifications = {}
  saved_notify = vim.notify
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
  end
  return notifications
end

local function git_cmd(repo_root, args)
  local cmd = { 'git', '-C', repo_root }
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end
  local output = vim.fn.systemlist(cmd)
  assert.are.equal(0, vim.v.shell_error, table.concat(output, '\n'))
  return output
end

local function create_repo()
  local repo_root = vim.fn.tempname()
  vim.fn.mkdir(repo_root, 'p')
  test_repos[#test_repos + 1] = repo_root

  vim.fn.systemlist({ 'git', 'init', '-q', repo_root })
  assert.are.equal(0, vim.v.shell_error)
  git_cmd(repo_root, { 'config', 'user.email', 'test@example.com' })
  git_cmd(repo_root, { 'config', 'user.name', 'Test' })
  git_cmd(repo_root, { 'config', 'core.filemode', 'true' })
  vim.fn.writefile({ 'line 1', 'line 2' }, repo_root .. '/file.txt')
  git_cmd(repo_root, { 'add', 'file.txt' })
  git_cmd(repo_root, { 'commit', '-qm', 'initial' })

  return repo_root
end

local function create_conflicted_repo()
  local repo_root = create_repo()
  local filepath = repo_root .. '/file.txt'
  local base = git_cmd(repo_root, { 'rev-parse', 'HEAD' })[1]

  git_cmd(repo_root, { 'checkout', '-qb', 'ours' })
  vim.fn.writefile({ 'line 1', 'line 2 ours' }, filepath)
  git_cmd(repo_root, { 'add', 'file.txt' })
  git_cmd(repo_root, { 'commit', '-qm', 'ours' })

  git_cmd(repo_root, { 'checkout', '-qb', 'theirs', base })
  vim.fn.writefile({ 'line 1', 'line 2 theirs' }, filepath)
  git_cmd(repo_root, { 'add', 'file.txt' })
  git_cmd(repo_root, { 'commit', '-qm', 'theirs' })

  local output = vim.fn.systemlist({ 'git', '-C', repo_root, 'merge', 'ours' })
  assert.are_not.equal(0, vim.v.shell_error, table.concat(output, '\n'))

  return repo_root, filepath
end

local function write_repo_file(repo_root, path, lines)
  local filepath = repo_root .. '/' .. path
  vim.fn.mkdir(vim.fn.fnamemodify(filepath, ':h'), 'p')
  vim.fn.writefile(lines, filepath)
  return filepath
end

local function create_review_repo(opts)
  opts = opts or {}
  local repo_root = vim.fn.tempname()
  vim.fn.mkdir(repo_root, 'p')
  test_repos[#test_repos + 1] = repo_root

  vim.fn.systemlist({ 'git', 'init', '-q', repo_root })
  assert.are.equal(0, vim.v.shell_error)
  git_cmd(repo_root, { 'config', 'user.email', 'test@example.com' })
  git_cmd(repo_root, { 'config', 'user.name', 'Test' })

  write_repo_file(repo_root, 'lua/one.lua', { 'old one' })
  write_repo_file(repo_root, 'lua/two.lua', {
    'line 1',
    'line 2',
    'line 3',
    'line 4',
    'line 5',
    'line 6',
    'line 7',
    'line 8',
    'line 9',
    'line 10',
    'line 11',
    'line 12',
  })
  git_cmd(repo_root, { 'add', 'lua' })
  git_cmd(repo_root, { 'commit', '-qm', 'base' })
  local base_sha = git_cmd(repo_root, { 'rev-parse', 'HEAD' })[1]

  local base_ref = base_sha
  local target_ref
  if opts.named_refs then
    git_cmd(repo_root, { 'branch', 'review-base' })
    git_cmd(repo_root, { 'checkout', '-qb', 'review-topic' })
    base_ref = 'review-base'
    target_ref = 'review-topic'
  end

  write_repo_file(repo_root, 'lua/one.lua', { 'new one' })
  write_repo_file(repo_root, 'lua/two.lua', {
    'line 1',
    'line 2 changed',
    'line 3',
    'line 4',
    'line 5',
    'line 6',
    'line 7',
    'line 8',
    'line 9',
    'line 10',
    'line 11 changed',
    'line 12',
  })

  local target_sha
  if opts.commit_target ~= false then
    git_cmd(repo_root, { 'add', 'lua' })
    git_cmd(repo_root, { 'commit', '-qm', 'target' })
    target_sha = git_cmd(repo_root, { 'rev-parse', 'HEAD' })[1]
    target_ref = target_ref or target_sha
  end

  return {
    repo_root = repo_root,
    base = base_ref,
    target = target_ref,
    base_sha = base_sha,
    target_sha = target_sha,
  }
end

local function create_current_state_review_repo()
  local repo_root = vim.fn.tempname()
  vim.fn.mkdir(repo_root, 'p')
  test_repos[#test_repos + 1] = repo_root

  vim.fn.systemlist({ 'git', 'init', '-q', repo_root })
  assert.are.equal(0, vim.v.shell_error)
  git_cmd(repo_root, { 'config', 'user.email', 'test@example.com' })
  git_cmd(repo_root, { 'config', 'user.name', 'Test' })

  write_repo_file(repo_root, 'lua/branch.lua', { 'branch base' })
  write_repo_file(repo_root, 'lua/dup.lua', { 'dup base' })
  write_repo_file(repo_root, 'lua/staged.lua', { 'staged base' })
  write_repo_file(repo_root, 'lua/unstaged.lua', { 'unstaged base' })
  git_cmd(repo_root, { 'add', 'lua' })
  git_cmd(repo_root, { 'commit', '-qm', 'base' })
  local base = git_cmd(repo_root, { 'rev-parse', 'HEAD' })[1]

  git_cmd(repo_root, { 'checkout', '-qb', 'topic' })
  write_repo_file(repo_root, 'lua/branch.lua', { 'branch head' })
  write_repo_file(repo_root, 'lua/dup.lua', { 'dup head' })
  git_cmd(repo_root, { 'add', 'lua/branch.lua', 'lua/dup.lua' })
  git_cmd(repo_root, { 'commit', '-qm', 'branch changes' })

  write_repo_file(repo_root, 'lua/dup.lua', { 'dup staged' })
  write_repo_file(repo_root, 'lua/staged.lua', { 'staged changed' })
  git_cmd(repo_root, { 'add', 'lua/dup.lua', 'lua/staged.lua' })

  write_repo_file(repo_root, 'lua/dup.lua', { 'dup unstaged' })
  write_repo_file(repo_root, 'lua/unstaged.lua', { 'unstaged changed' })
  write_repo_file(repo_root, 'lua/new.lua', { 'new file' })

  return {
    repo_root = repo_root,
    base = base,
  }
end

local function create_mode_only_review_repo()
  local repo_root = vim.fn.tempname()
  vim.fn.mkdir(repo_root, 'p')
  test_repos[#test_repos + 1] = repo_root

  vim.fn.systemlist({ 'git', 'init', '-q', repo_root })
  assert.are.equal(0, vim.v.shell_error)
  git_cmd(repo_root, { 'config', 'user.email', 'test@example.com' })
  git_cmd(repo_root, { 'config', 'user.name', 'Test' })
  git_cmd(repo_root, { 'config', 'core.filemode', 'true' })

  write_repo_file(repo_root, 'scripts/tool.sh', { '#!/bin/sh', 'echo tool' })
  git_cmd(repo_root, { 'add', 'scripts/tool.sh' })
  git_cmd(repo_root, { 'commit', '-qm', 'base' })
  git_cmd(repo_root, { 'branch', 'mode-base' })

  git_cmd(repo_root, { 'checkout', '-qb', 'mode-topic' })
  git_cmd(repo_root, { 'update-index', '--chmod=+x', 'scripts/tool.sh' })
  git_cmd(repo_root, { 'commit', '-qm', 'mode' })

  return {
    repo_root = repo_root,
    base = 'mode-base',
    target = 'mode-topic',
  }
end

local function edit_file(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  test_buffers[#test_buffers + 1] = bufnr
  return bufnr
end

local function write_binary_file(path, text)
  vim.fn.system({ 'sh', '-c', 'printf "$1" > "$2"', 'sh', text, path })
  assert.are.equal(0, vim.v.shell_error)
end

local function buffer_lines(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ok, rail_width = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_rail_width')
  if ok then
    return rails.strip_lines(lines, rail_width, rails.separator_width_for_buffer(bufnr))
  end
  return lines
end

local function buffer_text(bufnr)
  return table.concat(buffer_lines(bufnr), '\n')
end

local function quickfix_items()
  return vim.fn.getqflist({ items = 0 }).items
end

local function loclist_items(win)
  local nr = win and vim.fn.win_id2win(win) or 0
  return vim.fn.getloclist(nr, { items = 0 }).items
end

local function find_window_for_buffer(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function find_quickfix_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_get_option_value('buftype', { buf = buf }) == 'quickfix' then
      return win
    end
  end
  return nil
end

---@param win integer
---@return integer?
local function find_loclist_window_for_window(win)
  local winnr = vim.fn.win_id2win(win)
  if winnr == 0 then
    return nil
  end

  local loclist = vim.fn.getloclist(winnr, { winid = 0 })
  if type(loclist) ~= 'table' or type(loclist.winid) ~= 'number' or loclist.winid == 0 then
    return nil
  end
  return loclist.winid
end

local function find_buffer_line(bufnr, text)
  for lnum, line in ipairs(buffer_lines(bufnr)) do
    if line:find(text, 1, true) then
      return lnum
    end
  end
  return nil
end

local function find_buffer_line_after(bufnr, after_text, text)
  local start = find_buffer_line(bufnr, after_text)
  assert.is_not_nil(start)
  local lines = buffer_lines(bufnr)
  for lnum = start + 1, #lines do
    if lines[lnum]:find(text, 1, true) then
      return lnum
    end
  end
  return nil
end

local function has_buf_var(bufnr, name)
  local ok = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  return ok
end

local function restore_mocks()
  for k, v in pairs(saved_git) do
    git[k] = v
  end
  saved_git = {}
  if saved_runtime_attach then
    runtime.attach = saved_runtime_attach
    saved_runtime_attach = nil
  end
  if saved_runtime_get_conflict_config then
    runtime.get_conflict_config = saved_runtime_get_conflict_config
    saved_runtime_get_conflict_config = nil
  end
  if saved_runtime_get_view_config then
    runtime.get_view_config = saved_runtime_get_view_config
    saved_runtime_get_view_config = nil
  end
  if saved_runtime_get_highlight_opts then
    runtime.get_highlight_opts = saved_runtime_get_highlight_opts
    saved_runtime_get_highlight_opts = nil
  end
  if saved_schedule then
    vim.schedule = saved_schedule
    saved_schedule = nil
  end
  if saved_systemlist then
    vim.fn.systemlist = saved_systemlist
    saved_systemlist = nil
  end
  if saved_notify then
    vim.notify = saved_notify
    saved_notify = nil
  end
end

local function cleanup_buffers()
  for _, bufnr in ipairs(test_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  test_buffers = {}
end

local function cleanup_repos()
  for _, repo_root in ipairs(test_repos) do
    vim.fn.delete(repo_root, 'rf')
  end
  test_repos = {}
end

describe('commands', function()
  after_each(function()
    restore_mocks()
    cleanup_buffers()
    cleanup_repos()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      pcall(vim.api.nvim_set_option_value, 'winhighlight', '', { win = win })
    end
  end)

  describe('setup', function()
    it('registers the Diff command alongside the deprecated aliases', function()
      commands.setup()
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Diff)
      assert.is_true(cmds.Diff.bar)
      assert.is_not_nil(cmds.Gdiff)
      assert.is_not_nil(cmds.Gvdiff)
      assert.is_not_nil(cmds.Ghdiff)
      assert.is_not_nil(cmds.Greview)
      assert.is_true(cmds.Gdiff.bar)
      assert.is_true(cmds.Gvdiff.bar)
      assert.is_true(cmds.Ghdiff.bar)
      assert.is_true(cmds.Greview.bar)
    end)
  end)

  describe('Diff command dispatch', function()
    local function capture_dispatch(args, vertical)
      local saved_gdiff = commands.gdiff
      local saved_greview = commands.greview_command
      local captured = {}
      commands.gdiff = function(a, v, o)
        captured.gdiff = { args = a, vertical = v, opts = o }
      end
      commands.greview_command = function(a, v, o)
        captured.greview = { args = a, vertical = v, opts = o }
      end
      commands.diff_command(args, vertical)
      commands.gdiff = saved_gdiff
      commands.greview_command = saved_greview
      return captured
    end

    it('routes plain arguments to the current-file diff', function()
      local captured = capture_dispatch('HEAD~3', false)
      assert.is_nil(captured.greview)
      assert.are.same(
        { args = 'HEAD~3', vertical = false, opts = { warn_vertical_split = false } },
        captured.gdiff
      )
    end)

    it('threads the :vertical modifier and the split warning into the diff path', function()
      local captured = capture_dispatch(nil, true)
      assert.is_nil(captured.greview)
      assert.are.same(
        { args = nil, vertical = true, opts = { warn_vertical_split = true } },
        captured.gdiff
      )
    end)

    it('routes a leading review subcommand to the review surface', function()
      local captured = capture_dispatch('review origin/main', true)
      assert.is_nil(captured.gdiff)
      assert.are.same(
        { args = 'origin/main', vertical = true, opts = { warn_vertical_split = true } },
        captured.greview
      )
    end)

    it('treats a bare review subcommand as a review with no spec', function()
      local captured = capture_dispatch('review', false)
      assert.is_nil(captured.gdiff)
      assert.are.same(
        { args = nil, vertical = false, opts = { warn_vertical_split = false } },
        captured.greview
      )
    end)

    it('only treats review as the subcommand when it is the first token', function()
      local captured = capture_dispatch('++layout=split review', false)
      assert.is_nil(captured.greview)
      assert.are.same(
        { args = '++layout=split review', vertical = false, opts = { warn_vertical_split = false } },
        captured.gdiff
      )
    end)
  end)

  describe('deprecated command aliases', function()
    local deprecations = {
      Gdiff = '[diffs]: :Gdiff is deprecated, use :Diff instead.\n'
        .. 'Feature will be removed in diffs.nvim 0.4.0. See :help diffs.nvim-deprecated-commands',
      Gvdiff = '[diffs]: :Gvdiff is deprecated, use :vertical Diff instead.\n'
        .. 'Feature will be removed in diffs.nvim 0.4.0. See :help diffs.nvim-deprecated-commands',
      Ghdiff = '[diffs]: :Ghdiff is deprecated, use :Diff instead.\n'
        .. 'Feature will be removed in diffs.nvim 0.4.0. See :help diffs.nvim-deprecated-commands',
      Greview = '[diffs]: :Greview is deprecated, use :Diff review instead.\n'
        .. 'Feature will be removed in diffs.nvim 0.4.0. See :help diffs.nvim-deprecated-commands',
    }

    local function count_deprecations(notifications)
      local count = 0
      for _, n in ipairs(notifications) do
        if tostring(n.message):find('deprecated', 1, true) then
          count = count + 1
        end
      end
      return count
    end

    local function deprecation_messages(notifications)
      local messages = {}
      for _, n in ipairs(notifications) do
        if tostring(n.message):find('deprecated', 1, true) then
          messages[#messages + 1] = n.message
        end
      end
      return messages
    end

    it('warns on use of every deprecated alias', function()
      commands.setup()
      local notifications = capture_notifications()
      vim.cmd('enew')
      vim.cmd('silent! Gdiff')
      vim.cmd('silent! Gvdiff')
      vim.cmd('silent! Ghdiff')
      vim.cmd('silent! Greview ++layout=bogus')
      assert.are.equal(4, count_deprecations(notifications))
      assert.are.same({
        deprecations.Gdiff,
        deprecations.Gvdiff,
        deprecations.Ghdiff,
        deprecations.Greview,
      }, deprecation_messages(notifications))
    end)

    it('warns again on every repeated use of a deprecated alias', function()
      commands.setup()
      local notifications = capture_notifications()
      vim.cmd('enew')
      vim.cmd('silent! Gdiff')
      vim.cmd('silent! Gdiff')
      assert.are.equal(2, count_deprecations(notifications))
    end)

    it('does not warn for the :Diff command', function()
      commands.setup()
      local notifications = capture_notifications()
      vim.cmd('enew')
      vim.cmd('silent! Diff')
      assert.are.equal(0, count_deprecations(notifications))
    end)
  end)

  describe('generated rail style metadata', function()
    local function diff_lines(change)
      return {
        'diff --git a/lua/foo.lua b/lua/foo.lua',
        '--- a/lua/foo.lua',
        '+++ b/lua/foo.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+' .. change,
        ' return M',
      }
    end

    local function assert_single_rail_display(bufnr, change)
      local display_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      assert.are.equal(6, vim.api.nvim_buf_get_var(bufnr, 'diffs_rail_width'))
      assert.are.equal(3, vim.api.nvim_buf_get_var(bufnr, 'diffs_rail_separator_width'))
      assert.are.equal('single', vim.api.nvim_buf_get_var(bufnr, 'diffs_rail_style'))
      assert.are.equal('single', rails.style_for_buffer(bufnr))
      assert.are.equal('    | diff --git a/lua/foo.lua b/lua/foo.lua', display_lines[1])
      assert.is_true(table.concat(display_lines, '\n'):find('  2 | +' .. change, 1, true) ~= nil)
    end

    it('creates single-rail generated buffers and keeps hunk metadata raw', function()
      mock_view_config({ prefix = true, change_bar = '▏', rail_separator = '|' })

      local diff_spec = diffspec.index_to_worktree('lua/foo.lua')
      local bufnr = commands._test.create_generated_diff_buffer({
        name = 'diffs://unstaged:lua/foo.lua',
        lines = diff_lines('local x = 1'),
        repo_root = '/tmp/repo',
        diff_spec = diff_spec,
        source = generated.file_source('/tmp/repo', diff_spec),
        rail_style = 'single',
      })
      table.insert(test_buffers, bufnr)

      assert_single_rail_display(bufnr, 'local x = 1')

      local diff_hunks = vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('diff --git a/lua/foo.lua b/lua/foo.lua', diff_hunks[1].file_header_lines[1])
      assert.are.equal('@@ -1,2 +1,3 @@', diff_hunks[1].header)
      assert.are.equal('@@ -1,2 +1,3 @@', diff_hunks[1].lines[1].text)
      assert.are.equal(' local M = {}', diff_hunks[1].lines[2].text)
      assert.are.equal('+local x = 1', diff_hunks[1].lines[3].text)
      assert.are.equal(' return M', diff_hunks[1].lines[4].text)
    end)

    it('preserves single rails when generated buffers reload without an explicit style', function()
      mock_view_config({ prefix = true, change_bar = '▏', rail_separator = '|' })
      mock_runtime_attach(function() end)
      mock_systemlist(function(cmd)
        assert.are.same({
          'git',
          '-C',
          '/tmp/repo',
          'diff',
          '--no-ext-diff',
          '--no-color',
        }, cmd)
        return diff_lines('local reloaded = true')
      end)

      local bufnr = commands._test.create_generated_diff_buffer({
        name = 'diffs://unstaged:all',
        lines = diff_lines('local stale = true'),
        repo_root = '/tmp/repo',
        source = generated.section_source('/tmp/repo', 'unstaged'),
        rail_style = 'single',
      })
      table.insert(test_buffers, bufnr)

      commands.read_buffer(bufnr)

      assert_single_rail_display(bufnr, 'local reloaded = true')
      assert.is_true(buffer_text(bufnr):find('+local reloaded = true', 1, true) ~= nil)
      assert.is_false(buffer_text(bufnr):find('+local stale = true', 1, true) ~= nil)
    end)

    it('lets generated buffer replacement override an existing rail style', function()
      mock_view_config({ prefix = true, change_bar = '▏', rail_separator = '|' })

      local bufnr = commands._test.create_generated_diff_buffer({
        name = 'diffs://unstaged:all',
        lines = diff_lines('local single = true'),
        repo_root = '/tmp/repo',
        rail_style = 'single',
      })
      table.insert(test_buffers, bufnr)

      commands._test.replace_generated_diff_buffer_lines(
        bufnr,
        diff_lines('local dual = true'),
        nil,
        { rail_style = 'dual' }
      )

      local display_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(8, vim.api.nvim_buf_get_var(bufnr, 'diffs_rail_width'))
      assert.are.equal(3, vim.api.nvim_buf_get_var(bufnr, 'diffs_rail_separator_width'))
      assert.are.equal('dual', vim.api.nvim_buf_get_var(bufnr, 'diffs_rail_style'))
      assert.are.equal('dual', rails.style_for_buffer(bufnr))
      assert.are.equal('      | diff --git a/lua/foo.lua b/lua/foo.lua', display_lines[1])
      assert.is_true(
        table.concat(display_lines, '\n'):find('    2 | +local dual = true', 1, true) ~= nil
      )
    end)
  end)

  describe('command completion', function()
    it('completes Gdiff layout options and Fugitive-style objects', function()
      mock_repo_root(function()
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        assert.are.same({
          'git',
          '-C',
          '/tmp/repo',
          'for-each-ref',
          '--format=%(refname:short)',
          'refs/heads/',
          'refs/remotes/',
          'refs/tags/',
        }, cmd)
        return { 'origin/main', 'feature/topic' }
      end)

      assert.are.same({
        '++layout=unified',
        '++layout=stacked',
        '++layout=split',
      }, commands._test.complete_gdiff('++l'))
      assert.are.same({
        '++layout=unified',
        '++layout=stacked',
        '++layout=split',
        ':',
        ':%',
        ':0:%',
        '@:%',
        'origin/main',
        'feature/topic',
      }, commands._test.complete_gdiff('', 'Gdiff ', #'Gdiff '))
      assert.are.same({
        ':',
        ':%',
        ':0:%',
        '@:%',
        'origin/main',
        'feature/topic',
      }, commands._test.complete_gdiff('', 'Gdiff ++layout=split ', #'Gdiff ++layout=split '))
      assert.are.same({}, commands._test.complete_gdiff('', 'Gdiff HEAD ', #'Gdiff HEAD '))
      assert.are.same({ ':', ':%', ':0:%' }, commands._test.complete_gdiff(':'))
      assert.are.same({ ':0:%' }, commands._test.complete_gdiff(':0', 'Gdiff :0', #'Gdiff :0'))
      assert.are.same(
        { ':0:%' },
        commands._test.complete_gdiff(':0', 'vertical Gdiff :0', #'vertical Gdiff :0')
      )
      assert.are.same({ '@:%' }, commands._test.complete_gdiff('@'))
      assert.are.same({ 'origin/main' }, commands._test.complete_gdiff('origin/'))
    end)

    it('keeps Gvdiff and Ghdiff completion focused on objects', function()
      assert.are.same({}, commands._test.complete_gdiff_split('++l'))
    end)

    it('completes the Diff review subcommand, layout options, objects, and refs', function()
      mock_repo_root(function()
        return '/tmp/repo'
      end)
      mock_systemlist(function()
        return { 'origin/main', 'feature/topic' }
      end)

      assert.are.same({
        'review',
        '++layout=unified',
        '++layout=stacked',
        '++layout=split',
        ':',
        ':%',
        ':0:%',
        '@:%',
        'origin/main',
        'feature/topic',
      }, commands._test.complete_diff('', 'Diff ', #'Diff '))

      assert.are.same({ 'review' }, commands._test.complete_diff('rev', 'Diff rev', #'Diff rev'))

      assert.are.same({
        '++layout=unified',
        '++layout=stacked',
        '++layout=split',
      }, commands._test.complete_diff('++l', 'Diff ++l', #'Diff ++l'))

      assert.are.same({
        '++layout=unified',
        '++layout=stacked',
        '++layout=split',
        'origin/main',
        'feature/topic',
      }, commands._test.complete_diff('', 'Diff review ', #'Diff review '))

      assert.are.same(
        {
          'origin/main',
          'feature/topic',
        },
        commands._test.complete_diff(
          '',
          'Diff review ++layout=split ',
          #'Diff review ++layout=split '
        )
      )

      assert.are.same(
        {},
        commands._test.complete_diff('', 'Diff review origin/main ', #'Diff review origin/main ')
      )
      assert.are.same(
        {},
        commands._test.complete_diff(
          '',
          'Diff review ++layout=split origin/main ',
          #'Diff review ++layout=split origin/main '
        )
      )
      assert.are.same({}, commands._test.complete_diff('', 'Diff HEAD ', #'Diff HEAD '))
    end)
  end)

  describe('unified diff generation', function()
    local old_lines = { 'local M = {}', 'return M' }
    local new_lines = { 'local M = {}', 'local x = 1', 'return M' }
    local diff_fn = vim.text and vim.text.diff or vim.diff

    it('generates valid unified diff', function()
      local old_content = table.concat(old_lines, '\n')
      local new_content = table.concat(new_lines, '\n')
      local diff_output = diff_fn(old_content, new_content, {
        result_type = 'unified',
        ctxlen = 3,
      })
      assert.is_not_nil(diff_output)
      assert.is_true(diff_output:find('@@ ') ~= nil)
      assert.is_true(diff_output:find('+local x = 1') ~= nil)
    end)

    it('returns empty for identical content', function()
      local content = table.concat(old_lines, '\n')
      local diff_output = diff_fn(content, content, {
        result_type = 'unified',
        ctxlen = 3,
      })
      assert.are.equal('', diff_output)
    end)
  end)

  describe('filter_combined_diffs', function()
    it('strips diff --cc entries entirely', function()
      local lines = {
        'diff --cc main.lua',
        'index d13ab94,b113aee..0000000',
        '--- a/main.lua',
        '+++ b/main.lua',
        '@@@ -1,7 -1,7 +1,11 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        ' +  return 1',
        '++=======',
        '+   return 2',
        '++>>>>>>> theirs',
        '  end',
      }
      local result = commands.filter_combined_diffs(lines)
      assert.are.equal(0, #result)
    end)

    it('preserves diff --git entries', function()
      local lines = {
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,3 @@',
        ' local M = {}',
        '-local x = 1',
        '+local x = 2',
        ' return M',
      }
      local result = commands.filter_combined_diffs(lines)
      assert.are.equal(8, #result)
      assert.are.same(lines, result)
    end)

    it('strips combined but keeps unified in mixed output', function()
      local lines = {
        'diff --cc conflict.lua',
        'index aaa,bbb..000',
        '@@@ -1,1 -1,1 +1,5 @@@',
        '++<<<<<<< HEAD',
        'diff --git a/clean.lua b/clean.lua',
        '--- a/clean.lua',
        '+++ b/clean.lua',
        '@@ -1,1 +1,1 @@',
        '-old',
        '+new',
      }
      local result = commands.filter_combined_diffs(lines)
      assert.are.equal(6, #result)
      assert.are.equal('diff --git a/clean.lua b/clean.lua', result[1])
      assert.are.equal('+new', result[6])
    end)

    it('returns empty for empty input', function()
      local result = commands.filter_combined_diffs({})
      assert.are.equal(0, #result)
    end)

    it('returns empty when all entries are combined', function()
      local lines = {
        'diff --cc a.lua',
        'some content',
        'diff --cc b.lua',
        'more content',
      }
      local result = commands.filter_combined_diffs(lines)
      assert.are.equal(0, #result)
    end)
  end)

  describe('Gdiff DiffSpec rendering', function()
    local function create_split_source(opts)
      opts = opts or {}
      local filepath = opts.filepath or '/tmp/repo/lua/foo.lua'
      local relpath = opts.relpath or 'lua/foo.lua'
      local worktree_lines = opts.worktree_lines
        or {
          'local M = {}',
          'local x = 1',
          'return M',
        }
      local index_lines = opts.index_lines or { 'local M = {}', 'return M' }

      local source_buf = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, source_buf)
      vim.api.nvim_buf_set_name(source_buf, filepath)
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, worktree_lines)
      vim.api.nvim_set_option_value('filetype', 'lua', { buf = source_buf })
      vim.api.nvim_set_current_buf(source_buf)

      mock_git_method('get_relative_path', function(actual_filepath)
        assert.are.equal(filepath, actual_filepath)
        return relpath
      end)
      mock_git_method('get_index_content', function(actual_filepath)
        assert.are.equal(filepath, actual_filepath)
        return index_lines
      end)
      mock_repo_root(function(actual_filepath)
        assert.are.equal(filepath, actual_filepath)
        return '/tmp/repo'
      end)

      return source_buf
    end

    local function find_split_windows(left_buf, right_buf)
      local left_win
      local right_win
      local left_index
      local right_index
      for i, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local win_buf = vim.api.nvim_win_get_buf(win)
        if win_buf == left_buf then
          left_win = win
          left_index = i
        elseif win_buf == right_buf then
          right_win = win
          right_index = i
        end
      end

      return left_win, right_win, left_index, right_index
    end

    it('opens default :Gdiff as an unstaged index to worktree diff', function()
      local source_buf = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, source_buf)
      vim.api.nvim_buf_set_name(source_buf, '/tmp/repo/lua/foo.lua')
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
        'local M = {}',
        'local x = 1',
        'return M',
      })
      vim.api.nvim_set_current_buf(source_buf)

      local called_index = false
      local called_head = false
      mock_git_method('get_relative_path', function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return 'lua/foo.lua'
      end)
      mock_git_method('get_index_content', function(filepath)
        called_index = true
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return { 'local M = {}', 'return M' }
      end)
      mock_git_method('get_file_content', function()
        called_head = true
        return { 'should not be used' }
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return '/tmp/repo'
      end)
      mock_runtime_attach(function() end)
      mock_view_config({ prefix = true, change_bar = '▏', rail_separator = '|' })

      commands.gdiff(nil, false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      local lines = buffer_lines(diff_buf)

      assert.is_true(called_index)
      assert.is_false(called_head)
      assert.are.equal('diffs://unstaged:lua/foo.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.index_to_worktree('lua/foo.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local diff_hunks = vim.api.nvim_buf_get_var(diff_buf, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('lua/foo.lua', diff_hunks[1].file)
      assert.is_true(diff_hunks[1].can_put)
      assert.is_false(diff_hunks[1].can_obtain)
      assert.is_true(diff_hunks[1].actionable)
      assert.are.equal('worktree', diff_hunks[1].mutation_target)
      assert.is_true(helpers.has_keymap(diff_buf, ']c'))
      assert.is_true(helpers.has_keymap(diff_buf, '[c'))
      assert.is_true(helpers.has_keymap(diff_buf, '<CR>'))
      assert.is_false(helpers.has_keymap(diff_buf, 'o'))
      assert.is_false(helpers.has_keymap(diff_buf, 'do'))
      assert.is_true(helpers.has_keymap(diff_buf, 'dp'))
      assert.are.equal('diff --git a/lua/foo.lua b/lua/foo.lua', lines[1])
      assert.is_true(table.concat(lines, '\n'):find('+local x = 1', 1, true) ~= nil)

      local display_lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)
      assert.are.equal(8, vim.api.nvim_buf_get_var(diff_buf, 'diffs_rail_width'))
      assert.are.equal(3, vim.api.nvim_buf_get_var(diff_buf, 'diffs_rail_separator_width'))
      assert.are.equal('dual', vim.api.nvim_buf_get_var(diff_buf, 'diffs_rail_style'))
      assert.are.equal('      | diff --git a/lua/foo.lua b/lua/foo.lua', display_lines[1])
      assert.is_true(table.concat(display_lines, '\n'):find('    2 | +local x = 1', 1, true) ~= nil)

      local qf = quickfix_items()
      assert.are.equal(1, #qf)
      assert.are.equal(diff_buf, qf[1].bufnr)
      assert.are.equal(1, qf[1].lnum)
      assert.is_true(qf[1].text:find('lua/foo.lua', 1, true) ~= nil)

      local loc = loclist_items()
      assert.are.equal(1, #loc)
      assert.are.equal(diff_buf, loc[1].bufnr)
      assert.are.equal(diff_hunks[1].buffer_range.start, loc[1].lnum)
      assert.is_true(loc[1].text:find('lua/foo.lua', 1, true) ~= nil)
    end)

    it('opens stacked :Gdiff as a generated buffer with single rails', function()
      mock_runtime_attach(function() end)
      mock_view_config({ prefix = true, change_bar = '▏', rail_separator = '|' })
      create_split_source()

      commands.gdiff('++layout=stacked', false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      local display_lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)

      assert.are.equal('diffs://unstaged:lua/foo.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.index_to_worktree('lua/foo.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      assert.are.equal(6, vim.api.nvim_buf_get_var(diff_buf, 'diffs_rail_width'))
      assert.are.equal(3, vim.api.nvim_buf_get_var(diff_buf, 'diffs_rail_separator_width'))
      assert.are.equal('single', vim.api.nvim_buf_get_var(diff_buf, 'diffs_rail_style'))
      assert.are.equal('single', rails.style_for_buffer(diff_buf))
      assert.are.equal('    | diff --git a/lua/foo.lua b/lua/foo.lua', display_lines[1])
      assert.is_true(table.concat(display_lines, '\n'):find('  2 | +local x = 1', 1, true) ~= nil)
      assert.is_false(has_buf_var(diff_buf, 'diffs_split_peer'))

      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        assert.is_false(name:match('^diffs://split:') ~= nil)
      end
    end)

    it('opens default :Gdiff for untracked files as index to worktree additions', function()
      local source_buf = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, source_buf)
      vim.api.nvim_buf_set_name(source_buf, '/tmp/repo/lua/new.lua')
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
        'local M = {}',
        'return M',
      })
      vim.api.nvim_set_current_buf(source_buf)

      mock_git_method('get_relative_path', function(filepath)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return 'lua/new.lua'
      end)
      mock_git_method('get_index_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return nil, 'file not in index'
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return '/tmp/repo'
      end)
      mock_runtime_attach(function() end)

      commands.gdiff(nil, false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      local lines = buffer_lines(diff_buf)

      assert.are.equal('diffs://unstaged:lua/new.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.index_to_worktree('lua/new.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local text = table.concat(lines, '\n')
      assert.is_true(text:find('new file mode 100644', 1, true) ~= nil)
      assert.is_true(text:find('--- /dev/null', 1, true) ~= nil)
      assert.is_true(text:find('+local M = {}', 1, true) ~= nil)
    end)

    it('opens opt-in split :Gdiff as paired endpoint windows', function()
      local saved_splitright = vim.o.splitright
      vim.o.splitright = false
      local ok, err = pcall(function()
        mock_view_config({ prefix = true, change_bar = '┃', rail_separator = '│' })
        create_split_source()
        commands.gdiff('++layout=split', false)
      end)
      vim.o.splitright = saved_splitright
      assert.is_true(ok, err)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)
      local left_win, right_win, left_index, right_index = find_split_windows(left_buf, right_buf)

      assert.is_not_nil(left_win)
      assert.is_not_nil(right_win)
      assert.is_true(left_index < right_index)
      assert.are.equal('diffs://split:left:index:lua/foo.lua', vim.api.nvim_buf_get_name(left_buf))
      assert.are.equal(
        'diffs://split:right:worktree:lua/foo.lua',
        vim.api.nvim_buf_get_name(right_buf)
      )
      assert.are.same(
        { 'local M = {}', 'return M' },
        vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
      )
      assert.are.same(
        { 'local M = {}', 'local x = 1', 'return M' },
        vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)
      )
      assert.are.same(
        diffspec.index_to_worktree('lua/foo.lua'),
        vim.api.nvim_buf_get_var(left_buf, 'diffs_spec')
      )
      assert.are.equal('left', vim.api.nvim_buf_get_var(left_buf, 'diffs_split_side'))
      assert.are.equal('right', vim.api.nvim_buf_get_var(right_buf, 'diffs_split_side'))
      assert.are.equal('lua', vim.api.nvim_get_option_value('filetype', { buf = left_buf }))
      assert.are.equal('lua', vim.api.nvim_get_option_value('filetype', { buf = right_buf }))
      assert.is_false(vim.api.nvim_get_option_value('modifiable', { buf = left_buf }))
      assert.is_false(vim.api.nvim_get_option_value('modifiable', { buf = right_buf }))
      assert.is_true(vim.api.nvim_get_option_value('diff', { win = left_win }))
      assert.is_true(vim.api.nvim_get_option_value('diff', { win = right_win }))
      assert.are.equal('yes:1', vim.api.nvim_get_option_value('signcolumn', { win = left_win }))
      assert.are.equal('yes:1', vim.api.nvim_get_option_value('signcolumn', { win = right_win }))
      assert.are.equal('manual', vim.api.nvim_get_option_value('foldmethod', { win = left_win }))
      assert.are.equal('manual', vim.api.nvim_get_option_value('foldmethod', { win = right_win }))
      assert.is_false(vim.api.nvim_get_option_value('foldenable', { win = left_win }))
      assert.is_false(vim.api.nvim_get_option_value('foldenable', { win = right_win }))
      assert.are.equal('0', vim.api.nvim_get_option_value('foldcolumn', { win = left_win }))
      assert.are.equal('0', vim.api.nvim_get_option_value('foldcolumn', { win = right_win }))
      assert.is_true(vim.api.nvim_get_option_value('scrollbind', { win = left_win }))
      assert.is_true(vim.api.nvim_get_option_value('scrollbind', { win = right_win }))
      assert.is_true(vim.api.nvim_get_option_value('cursorbind', { win = left_win }))
      assert.is_true(vim.api.nvim_get_option_value('cursorbind', { win = right_win }))
      assert.are.equal(1, #vim.api.nvim_buf_get_var(right_buf, 'diffs_split_hunks'))
      assert.is_true(helpers.has_keymap(left_buf, 'q'))
      assert.is_true(helpers.has_keymap(right_buf, 'q'))
      assert.is_true(helpers.has_keymap(left_buf, '<CR>'))
      assert.is_true(helpers.has_keymap(right_buf, '<CR>'))
      assert.is_true(helpers.has_keymap(left_buf, ']c'))
      assert.is_true(helpers.has_keymap(right_buf, ']c'))
      assert.is_true(helpers.has_keymap(left_buf, '[c'))
      assert.is_true(helpers.has_keymap(right_buf, '[c'))
      assert.is_false(helpers.has_keymap(right_buf, 'dp'))
      assert.is_false(helpers.has_keymap(right_buf, 'do'))

      local bar_ns = vim.api.nvim_get_namespaces().diffs_split_change_bar
      local right_bars = vim.api.nvim_buf_get_extmarks(right_buf, bar_ns, 0, -1, {
        details = true,
      })
      local has_added_line_bar = false
      for _, mark in ipairs(right_bars) do
        local details = mark[4]
        if
          mark[2] == 1
          and details.sign_hl_group == 'DiffsAddBar'
          and details.sign_text == '┃ '
        then
          has_added_line_bar = true
        end
      end
      assert.is_true(has_added_line_bar)

      local qf = quickfix_items()
      assert.are.equal(1, #qf)
      assert.are.equal(right_buf, qf[1].bufnr)
      assert.are.equal(1, qf[1].lnum)
      assert.is_true(qf[1].text:find('lua/foo.lua', 1, true) ~= nil)

      local left_loc = loclist_items(left_win)
      local right_loc = loclist_items(right_win)
      assert.are.equal(1, #left_loc)
      assert.are.equal(1, #right_loc)
      assert.are.equal(left_buf, left_loc[1].bufnr)
      assert.are.equal(right_buf, right_loc[1].bufnr)
    end)

    it('paints the configured intra word-diff overlay on both split panes', function()
      mock_view_config({ prefix = true, change_bar = '┃', rail_separator = '│' })
      create_split_source({
        index_lines = { 'function f()', '  return 111', '  log()', 'end' },
        worktree_lines = { 'function f()', '  return 222', '  log()', 'end' },
      })
      commands.gdiff('++layout=split', false)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)
      local left_win, right_win = find_split_windows(left_buf, right_buf)

      local intra_ns = vim.api.nvim_get_namespaces().diffs_split_intra
      assert.is_not_nil(intra_ns)

      local function intra_mark(bufnr, group)
        for _, mark in
          ipairs(vim.api.nvim_buf_get_extmarks(bufnr, intra_ns, 0, -1, { details = true }))
        do
          if mark[4].hl_group == group then
            return mark
          end
        end
        return nil
      end

      local left_mark = intra_mark(left_buf, 'DiffsDeleteText')
      local right_mark = intra_mark(right_buf, 'DiffsAddText')
      assert.is_not_nil(left_mark)
      assert.is_not_nil(right_mark)
      assert.are.equal(1, left_mark[2])
      assert.are.equal(9, left_mark[3])
      assert.are.equal(12, left_mark[4].end_col)
      assert.are.equal(1, right_mark[2])
      assert.are.equal(9, right_mark[3])
      assert.are.equal(12, right_mark[4].end_col)

      assert.is_true(
        vim.api
          .nvim_get_option_value('winhighlight', { win = left_win })
          :find('DiffText:DiffsDiffChange', 1, true) ~= nil
      )
      assert.is_true(
        vim.api
          .nvim_get_option_value('winhighlight', { win = right_win })
          :find('DiffText:DiffsDiffChange', 1, true) ~= nil
      )
    end)

    it('skips the intra overlay when highlights.intra is disabled', function()
      mock_view_config({ prefix = true, change_bar = '┃', rail_separator = '│' })
      mock_highlight_opts(function(opts)
        opts.highlights.intra.enabled = false
      end)
      create_split_source({
        index_lines = { 'function f()', '  return 111', '  log()', 'end' },
        worktree_lines = { 'function f()', '  return 222', '  log()', 'end' },
      })
      commands.gdiff('++layout=split', false)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)

      local intra_ns = vim.api.nvim_get_namespaces().diffs_split_intra
      assert.is_not_nil(intra_ns)
      assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(left_buf, intra_ns, 0, -1, {}))
      assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(right_buf, intra_ns, 0, -1, {}))
    end)

    it('keeps the split DiffText suppression when attach_diff re-runs', function()
      mock_view_config({ prefix = true, change_bar = '┃', rail_separator = '│' })
      create_split_source()
      commands.gdiff('++layout=split', false)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)
      local left_win, right_win = find_split_windows(left_buf, right_buf)

      runtime.attach_diff()

      assert.is_true(
        vim.api
          .nvim_get_option_value('winhighlight', { win = left_win })
          :find('DiffText:DiffsDiffChange', 1, true) ~= nil
      )
      assert.is_true(
        vim.api
          .nvim_get_option_value('winhighlight', { win = right_win })
          :find('DiffText:DiffsDiffChange', 1, true) ~= nil
      )
    end)

    it('warns and still opens the split when :vertical Diff ++layout=split is used', function()
      local notifications = capture_notifications()
      local saved_splitright = vim.o.splitright
      vim.o.splitright = false
      local ok, err = pcall(function()
        mock_view_config({ prefix = true, change_bar = '┃', rail_separator = '│' })
        create_split_source()
        commands.diff_command('++layout=split', true)
      end)
      vim.o.splitright = saved_splitright
      assert.is_true(ok, err)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)
      local left_win, right_win = find_split_windows(left_buf, right_buf)
      assert.is_not_nil(left_win)
      assert.is_not_nil(right_win)

      local warned = false
      for _, n in ipairs(notifications) do
        if tostring(n.message):find('++layout=split ignores the :vertical modifier', 1, true) then
          warned = true
        end
      end
      assert.is_true(warned)
    end)

    it('moves split hunk navigation through both endpoint windows', function()
      create_split_source({
        index_lines = {
          'line 1',
          'line 2',
          'line 3',
          'line 4',
          'line 5',
          'line 6',
          'line 7',
          'line 8',
          'line 9',
          'line 10',
          'line 11',
          'line 12',
        },
        worktree_lines = {
          'line 1',
          'line 2 changed',
          'line 3',
          'line 4',
          'line 5',
          'line 6',
          'line 7',
          'line 8',
          'line 9',
          'line 10',
          'line 11 changed',
          'line 12',
        },
      })
      commands.gdiff('++layout=split', false)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)
      local left_win, right_win = find_split_windows(left_buf, right_buf)
      local hunks = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_hunks')

      assert.are.equal(2, #hunks)
      local right_loc = loclist_items(right_win)
      assert.are.equal(2, #right_loc)
      assert.are.equal(right_buf, right_loc[2].bufnr)
      assert.are.equal(hunks[2].new_range.start, right_loc[2].lnum)

      vim.api.nvim_set_current_win(right_win)
      vim.api.nvim_win_set_cursor(right_win, { hunks[1].new_range.start, 0 })

      split.goto_next(right_buf)

      assert.are.same({ hunks[2].old_range.start, 0 }, vim.api.nvim_win_get_cursor(left_win))
      assert.are.same({ hunks[2].new_range.start, 0 }, vim.api.nvim_win_get_cursor(right_win))

      split.goto_prev(right_buf)

      assert.are.same({ hunks[1].old_range.start, 0 }, vim.api.nvim_win_get_cursor(left_win))
      assert.are.same({ hunks[1].new_range.start, 0 }, vim.api.nvim_win_get_cursor(right_win))

      vim.api.nvim_set_current_win(right_win)
      vim.cmd('lopen')
      local found_qf = false
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_get_option_value('buftype', { buf = buf }) == 'quickfix' then
          vim.api.nvim_set_current_win(win)
          found_qf = true
          break
        end
      end
      assert.is_true(found_qf)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.cmd('normal \r')
      vim.wait(100, function()
        return vim.api.nvim_win_get_cursor(left_win)[1] == hunks[2].old_range.start
      end)

      assert.are.same({ hunks[2].old_range.start, 0 }, vim.api.nvim_win_get_cursor(left_win))
      assert.are.same({ hunks[2].new_range.start, 0 }, vim.api.nvim_win_get_cursor(right_win))
    end)

    it('targets the old endpoint for split deleted hunks in qf and loclist', function()
      create_split_source({
        index_lines = {
          'line 1',
          'line 2',
          'line 3',
        },
        worktree_lines = {},
      })
      commands.gdiff('++layout=split', false)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)
      local left_win, right_win = find_split_windows(left_buf, right_buf)
      local hunks = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_hunks')

      assert.are.equal(1, #hunks)
      assert.are.equal(0, hunks[1].new_range.count)

      local qf = quickfix_items()
      assert.are.equal(1, #qf)
      assert.are.equal(left_buf, qf[1].bufnr)
      assert.are.equal(hunks[1].old_range.start, qf[1].lnum)

      local right_loc = loclist_items(right_win)
      assert.are.equal(1, #right_loc)
      assert.are.equal(left_buf, right_loc[1].bufnr)
      assert.are.equal(hunks[1].old_range.start, right_loc[1].lnum)

      vim.api.nvim_set_current_win(right_win)
      vim.cmd('lopen')
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_get_option_value('buftype', { buf = buf }) == 'quickfix' then
          vim.api.nvim_set_current_win(win)
          break
        end
      end
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.cmd('normal \r')
      vim.wait(100, function()
        return vim.api.nvim_get_current_buf() == left_buf
          and vim.api.nvim_win_get_cursor(left_win)[1] == hunks[1].old_range.start
      end)

      assert.are.equal(left_buf, vim.api.nvim_get_current_buf())
      assert.are.same({ hunks[1].old_range.start, 0 }, vim.api.nvim_win_get_cursor(left_win))
    end)

    it('opens the worktree split endpoint in an existing source window', function()
      local notifications = capture_notifications()
      local source_buf = create_split_source()
      commands.gdiff('++layout=split', false)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)
      local left_win, right_win = find_split_windows(left_buf, right_buf)

      vim.api.nvim_set_current_win(right_win)
      vim.cmd('belowright split')
      local source_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(source_win, source_buf)

      vim.api.nvim_set_current_win(right_win)
      vim.api.nvim_win_set_cursor(right_win, { 2, 0 })
      assert.is_true(split.open_source(right_buf))

      assert.are.equal(source_win, vim.api.nvim_get_current_win())
      assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(source_win))

      vim.api.nvim_set_current_win(left_win)
      assert.is_false(split.open_source(left_buf))
      assert.is_true(
        notifications[#notifications].message:find('index-backed split endpoint', 1, true) ~= nil
      )
    end)

    it(
      'opens the worktree split endpoint in the invoking window when no source window exists',
      function()
        local source_buf = create_split_source()
        vim.api.nvim_set_option_value('diff', false, { win = 0 })
        vim.api.nvim_set_option_value('scrollbind', false, { win = 0 })
        vim.api.nvim_set_option_value('cursorbind', false, { win = 0 })
        vim.api.nvim_set_option_value('foldenable', true, { win = 0 })

        commands.gdiff('++layout=split', false)

        local right_buf = vim.api.nvim_get_current_buf()
        local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
        table.insert(test_buffers, left_buf)
        table.insert(test_buffers, right_buf)
        local left_win, right_win = find_split_windows(left_buf, right_buf)

        vim.api.nvim_set_current_win(right_win)
        vim.api.nvim_win_set_cursor(right_win, { 2, 0 })
        assert.is_true(split.open_source(right_buf))

        assert.are.equal(right_win, vim.api.nvim_get_current_win())
        assert.are.equal(source_buf, vim.api.nvim_get_current_buf())
        assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(right_win))
        assert.is_false(vim.api.nvim_buf_is_valid(left_buf))
        assert.is_false(vim.api.nvim_buf_is_valid(right_buf))
        assert.is_false(vim.api.nvim_win_is_valid(left_win))
        assert.is_true(vim.api.nvim_win_is_valid(right_win))
        assert.is_false(vim.api.nvim_get_option_value('diff', { win = right_win }))
        assert.is_false(vim.api.nvim_get_option_value('scrollbind', { win = right_win }))
        assert.is_false(vim.api.nvim_get_option_value('cursorbind', { win = right_win }))
        assert.is_true(vim.api.nvim_get_option_value('foldenable', { win = right_win }))
      end
    )

    it('cleans up the peer endpoint when one split buffer is wiped', function()
      create_split_source()
      commands.gdiff('++layout=split', false)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)

      vim.api.nvim_buf_delete(left_buf, { force = true })

      vim.wait(100, function()
        return not vim.api.nvim_buf_is_valid(right_buf)
      end)

      assert.is_false(vim.api.nvim_buf_is_valid(left_buf))
      assert.is_false(vim.api.nvim_buf_is_valid(right_buf))
    end)

    it('closes paired split endpoint buffers with q and can reopen the same split', function()
      local source_buf = create_split_source()

      commands.gdiff('++layout=split', false)

      local right_buf = vim.api.nvim_get_current_buf()
      local left_buf = vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer')
      table.insert(test_buffers, left_buf)
      table.insert(test_buffers, right_buf)
      local _, right_win = find_split_windows(left_buf, right_buf)

      vim.api.nvim_set_current_win(right_win)
      vim.cmd('normal q')

      assert.is_false(vim.api.nvim_buf_is_valid(left_buf))
      assert.is_false(vim.api.nvim_buf_is_valid(right_buf))

      vim.api.nvim_set_current_buf(source_buf)
      assert.has_no.errors(function()
        commands.gdiff('++layout=split', false)
      end)

      local reopened_right_buf = vim.api.nvim_get_current_buf()
      local reopened_left_buf = vim.api.nvim_buf_get_var(reopened_right_buf, 'diffs_split_peer')
      table.insert(test_buffers, reopened_left_buf)
      table.insert(test_buffers, reopened_right_buf)

      assert.are.equal(
        'diffs://split:left:index:lua/foo.lua',
        vim.api.nvim_buf_get_name(reopened_left_buf)
      )
      assert.are.equal(
        'diffs://split:right:worktree:lua/foo.lua',
        vim.api.nvim_buf_get_name(reopened_right_buf)
      )
    end)

    it('reopens stale split endpoint buffers from the invoking source window', function()
      local source_buf = create_split_source()
      commands.gdiff('++layout=split', false)

      local old_right_buf = vim.api.nvim_get_current_buf()
      local old_left_buf = vim.api.nvim_buf_get_var(old_right_buf, 'diffs_split_peer')
      table.insert(test_buffers, old_left_buf)
      table.insert(test_buffers, old_right_buf)

      local scratch_buf = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, scratch_buf)
      vim.cmd('topleft split')
      local scratch_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(scratch_win, scratch_buf)

      vim.cmd('botright split')
      local invoking_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(invoking_win, source_buf)

      commands.gdiff('++layout=split', false)

      local reopened_right_buf = vim.api.nvim_get_current_buf()
      local reopened_left_buf = vim.api.nvim_buf_get_var(reopened_right_buf, 'diffs_split_peer')
      table.insert(test_buffers, reopened_left_buf)
      table.insert(test_buffers, reopened_right_buf)
      local reopened_left_win, reopened_right_win =
        find_split_windows(reopened_left_buf, reopened_right_buf)

      assert.is_false(vim.api.nvim_buf_is_valid(old_left_buf))
      assert.is_false(vim.api.nvim_buf_is_valid(old_right_buf))
      assert.are.equal(invoking_win, reopened_left_win)
      assert.are.equal(reopened_right_win, vim.api.nvim_get_current_win())
      assert.are.equal(scratch_buf, vim.api.nvim_win_get_buf(scratch_win))
    end)

    it('preserves the explicit revision generated buffer surface', function()
      local source_buf = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, source_buf)
      vim.api.nvim_buf_set_name(source_buf, '/tmp/repo/lua/foo.lua')
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
        'local M = {}',
        'local x = 1',
        'return M',
      })
      vim.api.nvim_set_current_buf(source_buf)

      local captured_revision
      mock_git_method('get_relative_path', function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return 'lua/foo.lua'
      end)
      mock_git_method('get_file_content', function(revision, filepath)
        captured_revision = revision
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return { 'local M = {}', 'return M' }
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return '/tmp/repo'
      end)
      mock_runtime_attach(function() end)

      commands.gdiff('HEAD~3', false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      local lines = buffer_lines(diff_buf)

      assert.are.equal('HEAD~3', captured_revision)
      assert.are.equal('diffs://HEAD~3:lua/foo.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.equal('/tmp/repo', vim.api.nvim_buf_get_var(diff_buf, 'diffs_repo_root'))
      assert.are.same(
        diffspec.rev_to_worktree('HEAD~3', 'lua/foo.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local diff_hunks = vim.api.nvim_buf_get_var(diff_buf, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('lua/foo.lua', diff_hunks[1].file)
      assert.is_false(diff_hunks[1].can_put)
      assert.is_false(diff_hunks[1].can_obtain)
      assert.is_false(diff_hunks[1].actionable)
      assert.are.equal('worktree', diff_hunks[1].mutation_target)
      assert.are.equal('diff --git a/lua/foo.lua b/lua/foo.lua', lines[1])
      assert.are.equal('--- a/lua/foo.lua', lines[2])
      assert.are.equal('+++ b/lua/foo.lua', lines[3])
      assert.is_true(table.concat(lines, '\n'):find('+local x = 1', 1, true) ~= nil)
    end)
  end)

  describe('Gdiff real repository rendering', function()
    it('reports no unstaged changes for staged-only tracked files', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/file.txt'
      vim.fn.writefile({ 'line 1', 'line 2 staged' }, filepath)
      git_cmd(repo_root, { 'add', 'file.txt' })
      local source_buf = edit_file(filepath)
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      commands.gdiff(nil, false)

      assert.are.equal(source_buf, vim.api.nvim_get_current_buf())
      assert.is_true(
        notifications[#notifications].message:find('no changes for index -> worktree', 1, true)
          ~= nil
      )
    end)

    it('reports no unstaged changes for staged additions matching the worktree', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/new.txt'
      vim.fn.writefile({ 'new line' }, filepath)
      git_cmd(repo_root, { 'add', 'new.txt' })
      local source_buf = edit_file(filepath)
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      commands.gdiff(nil, false)

      assert.are.equal(source_buf, vim.api.nvim_get_current_buf())
      assert.is_true(
        notifications[#notifications].message:find('no changes for index -> worktree', 1, true)
          ~= nil
      )
    end)

    it('reports no unstaged changes for staged deletions matching the worktree', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/file.txt'
      git_cmd(repo_root, { 'rm', '-q', 'file.txt' })
      local source_buf = edit_file(filepath)
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      commands.gdiff(nil, false)

      assert.are.equal(source_buf, vim.api.nvim_get_current_buf())
      assert.is_true(
        notifications[#notifications].message:find('no changes for index -> worktree', 1, true)
          ~= nil
      )
    end)

    it('shows only the unstaged edge when a file has staged and unstaged changes', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/file.txt'
      vim.fn.writefile({ 'line 1', 'line 2 staged' }, filepath)
      git_cmd(repo_root, { 'add', 'file.txt' })
      vim.fn.writefile({ 'line 1', 'line 2 unstaged' }, filepath)
      edit_file(filepath)
      mock_runtime_attach(function() end)

      commands.gdiff(nil, false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      local text = buffer_text(diff_buf)
      assert.is_true(text:find('-line 2 staged', 1, true) ~= nil)
      assert.is_true(text:find('+line 2 unstaged', 1, true) ~= nil)
      assert.is_false(text:find('-line 2\n', 1, true) ~= nil)
    end)

    it('uses buffer EOF state for final-newline-only direct diffs', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/file.txt'
      vim.fn.writefile({ 'line 1', 'line 2' }, filepath, 'b')
      local source_buf = edit_file(filepath)
      mock_runtime_attach(function() end)

      assert.is_false(vim.bo[source_buf].endofline)

      commands.gdiff(nil, false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      local text = buffer_text(diff_buf)
      assert.is_true(text:find('-line 2', 1, true) ~= nil)
      assert.is_true(text:find('+line 2', 1, true) ~= nil)
      assert.is_true(text:find('\\ No newline at end of file', 1, true) ~= nil)
    end)

    it('reports mode-only direct changes instead of rendering fake text hunks', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/file.txt'
      vim.fn.setfperm(filepath, 'rwxr-xr-x')
      local source_buf = edit_file(filepath)
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      commands.gdiff(nil, false)

      assert.are.equal(source_buf, vim.api.nvim_get_current_buf())
      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
      assert.is_true(
        notifications[#notifications].message:find(
          'Gdiff does not support mode-only changes',
          1,
          true
        ) ~= nil
      )
    end)

    it('reports mode-only status-row changes without rendering text hunks', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/file.txt'
      vim.fn.setfperm(filepath, 'rwxr-xr-x')
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      commands.gdiff_file(filepath)

      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
      assert.is_true(
        notifications[#notifications].message:find(
          'Gdiff does not support mode-only changes',
          1,
          true
        ) ~= nil
      )
    end)

    it('reports binary status-row changes without rendering text hunks', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/bin.dat'
      write_binary_file(filepath, 'binary\\000old')
      git_cmd(repo_root, { 'add', 'bin.dat' })
      git_cmd(repo_root, { 'commit', '-qm', 'binary' })
      write_binary_file(filepath, 'binary\\000new')
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      commands.gdiff_file(filepath)

      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
      assert.is_true(
        notifications[#notifications].message:find('Gdiff does not support binary files', 1, true)
          ~= nil
      )
    end)

    it('reports submodule status-row changes without rendering pseudo text hunks', function()
      local repo_root = create_repo()
      local submodule_path = repo_root .. '/submodule'
      git_cmd(repo_root, {
        'update-index',
        '--add',
        '--cacheinfo',
        '160000,0123456789012345678901234567890123456789,submodule',
      })
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      commands.gdiff_file(submodule_path, { staged = true })

      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
      assert.is_true(
        notifications[#notifications].message:find(
          'Gdiff does not support submodule changes',
          1,
          true
        ) ~= nil
      )
    end)

    it('reports pure status-row renames as no text changes with actions unavailable', function()
      local repo_root = create_repo()
      local old_filepath = repo_root .. '/file.txt'
      local new_filepath = repo_root .. '/renamed.txt'
      git_cmd(repo_root, { 'mv', 'file.txt', 'renamed.txt' })
      local source_buf = edit_file(new_filepath)
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      commands.gdiff_file(new_filepath, { staged = true, old_filepath = old_filepath })

      assert.are.equal(source_buf, vim.api.nvim_get_current_buf())
      assert.are.equal(vim.log.levels.INFO, notifications[#notifications].level)
      assert.is_true(
        notifications[#notifications].message:find(
          'no text changes for staged rename/copy file.txt -> renamed.txt',
          1,
          true
        ) ~= nil
      )
      assert.is_true(
        notifications[#notifications].message:find(
          'generated hunk actions are unavailable',
          1,
          true
        ) ~= nil
      )
    end)

    it('renders status-row rename content changes without hunk actions', function()
      local repo_root = create_repo()
      local old_filepath = repo_root .. '/file.txt'
      local new_filepath = repo_root .. '/renamed.txt'
      git_cmd(repo_root, { 'mv', 'file.txt', 'renamed.txt' })
      vim.fn.writefile({ 'line 1', 'line 2 renamed' }, new_filepath)
      git_cmd(repo_root, { 'add', 'renamed.txt' })
      mock_runtime_attach(function() end)

      commands.gdiff_file(new_filepath, { staged = true, old_filepath = old_filepath })

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      local text = buffer_text(diff_buf)
      assert.are.equal('diffs://staged:renamed.txt', vim.api.nvim_buf_get_name(diff_buf))
      assert.is_true(text:find('diff --git a/file.txt b/renamed.txt', 1, true) ~= nil)
      assert.is_true(text:find('-line 2', 1, true) ~= nil)
      assert.is_true(text:find('+line 2 renamed', 1, true) ~= nil)
      assert.is_false(has_buf_var(diff_buf, 'diffs_hunks'))
      assert.is_false(helpers.has_keymap(diff_buf, 'do'))
      assert.is_false(helpers.has_keymap(diff_buf, 'dp'))
      assert.are.same({
        version = 1,
        kind = 'file_pair',
        repo_root = repo_root,
        edge = 'staged',
        path = 'renamed.txt',
        old_path = 'file.txt',
      }, vim.api.nvim_buf_get_var(diff_buf, 'diffs_source'))

      local qf = quickfix_items()
      assert.are.equal(1, #qf)
      assert.are.equal(diff_buf, qf[1].bufnr)
      assert.are.equal(1, qf[1].lnum)
      assert.is_true(qf[1].text:find('renamed.txt', 1, true) ~= nil)

      local loc = loclist_items()
      assert.are.equal(1, #loc)
      assert.are.equal(diff_buf, loc[1].bufnr)
      assert.is_true(loc[1].lnum > 1)
      assert.is_true(loc[1].text:find('renamed.txt', 1, true) ~= nil)
    end)

    it('opens staged and unstaged section headers as explicit section buffers', function()
      local repo_root = create_repo()
      vim.fn.writefile({ 'line 1', 'line 2 staged' }, repo_root .. '/file.txt')
      git_cmd(repo_root, { 'add', 'file.txt' })
      vim.fn.writefile({ 'line 1', 'line 2 staged', 'line 3 unstaged' }, repo_root .. '/file.txt')
      mock_runtime_attach(function() end)

      commands.gdiff_section(repo_root, { staged = true })
      local staged_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, staged_buf)
      assert.are.equal('diffs://staged:all', vim.api.nvim_buf_get_name(staged_buf))
      assert.is_true(buffer_text(staged_buf):find('+line 2 staged', 1, true) ~= nil)
      assert.is_false(has_buf_var(staged_buf, 'diffs_hunks'))
      assert.are.same({
        version = 1,
        kind = 'section',
        repo_root = repo_root,
        section = 'staged',
      }, vim.api.nvim_buf_get_var(staged_buf, 'diffs_source'))

      commands.gdiff_section(repo_root)
      local unstaged_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, unstaged_buf)
      assert.are.equal('diffs://unstaged:all', vim.api.nvim_buf_get_name(unstaged_buf))
      assert.is_true(buffer_text(unstaged_buf):find('+line 3 unstaged', 1, true) ~= nil)
      assert.is_false(has_buf_var(unstaged_buf, 'diffs_hunks'))
      assert.are.same({
        version = 1,
        kind = 'section',
        repo_root = repo_root,
        section = 'unstaged',
      }, vim.api.nvim_buf_get_var(unstaged_buf, 'diffs_source'))
    end)

    it('renders an explicit-path object against that path worktree counterpart', function()
      local repo_root = create_repo()
      write_repo_file(repo_root, 'other.lua', { 'local a = 1', 'return a' })
      git_cmd(repo_root, { 'add', 'other.lua' })
      git_cmd(repo_root, { 'commit', '-qm', 'add other' })
      vim.fn.writefile({ 'local a = 1', 'local b = 2', 'return a' }, repo_root .. '/other.lua')
      edit_file(repo_root .. '/file.txt')
      mock_runtime_attach(function() end)

      commands.diff_command('HEAD:other.lua', false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      assert.are.equal('diffs://HEAD:other.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.rev_to_worktree('HEAD', 'other.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local text = table.concat(buffer_lines(diff_buf), '\n')
      assert.is_true(text:find('+local b = 2', 1, true) ~= nil)
    end)

    it('renders a read-only merge-stage object against the worktree', function()
      local _, filepath = create_conflicted_repo()
      edit_file(filepath)
      mock_runtime_attach(function() end)
      assert.is_true(git.is_unmerged(filepath))

      commands.diff_command(':2:%', false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)
      assert.are.equal('diffs://stage2:file.txt', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.stage_to_worktree(2, 'file.txt'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      assert.is_false(helpers.has_keymap(diff_buf, 'dp'))
      assert.is_false(helpers.has_keymap(diff_buf, 'do'))
    end)

    it('rejects a merge-stage object when the file is not in a conflict', function()
      local repo_root = create_repo()
      edit_file(repo_root .. '/file.txt')
      mock_runtime_attach(function() end)
      local notifications = capture_notifications()

      commands.diff_command(':2:%', false)

      local rejected = false
      for _, n in ipairs(notifications) do
        if tostring(n.message):find('is not in a merge conflict', 1, true) then
          rejected = true
        end
      end
      assert.is_true(rejected)
    end)

    it('routes direct :Gdiff on unmerged files to the generated unmerged view', function()
      local repo_root, filepath = create_conflicted_repo()
      edit_file(filepath)
      local source_win = vim.api.nvim_get_current_win()
      mock_runtime_attach(function() end)
      mock_conflict_config({
        keymaps = helpers.default_conflict_keymaps(),
        show_virtual_text = false,
      })

      assert.is_true(git.is_unmerged(filepath))

      commands.gdiff(nil, false)

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)

      local function assert_unmerged_view(bufnr, expected_rail_style)
        local lines = buffer_lines(bufnr)
        local text = table.concat(lines, '\n')

        assert.are.equal('diffs://unmerged:file.txt', vim.api.nvim_buf_get_name(bufnr))
        assert.are.equal(repo_root, vim.api.nvim_buf_get_var(bufnr, 'diffs_repo_root'))
        assert.are.same({
          version = 1,
          kind = 'unmerged',
          repo_root = repo_root,
          path = 'file.txt',
          working_path = filepath,
        }, vim.api.nvim_buf_get_var(bufnr, 'diffs_source'))
        assert.is_true(vim.api.nvim_buf_get_var(bufnr, 'diffs_unmerged'))
        assert.are.equal(filepath, vim.api.nvim_buf_get_var(bufnr, 'diffs_working_path'))
        assert.is_false(has_buf_var(bufnr, 'diffs_spec'))
        assert.is_false(has_buf_var(bufnr, 'diffs_hunks'))
        assert.are.equal('diff --git a/file.txt b/file.txt', lines[1])
        assert.is_true(text:find('-line 2 theirs', 1, true) ~= nil)
        assert.is_true(text:find('+line 2 ours', 1, true) ~= nil)
        assert.is_true(text:find('--- /dev/null', 1, true) == nil)
        assert.is_true(text:find('new file mode', 1, true) == nil)
        assert.is_true(text:find('<<<<<<<', 1, true) == nil)
        assert.is_true(helpers.has_keymap(bufnr, 'go'))
        assert.is_true(helpers.has_keymap(bufnr, 'gt'))
        if expected_rail_style then
          assert.are.equal(expected_rail_style, vim.api.nvim_buf_get_var(bufnr, 'diffs_rail_style'))
        end
      end

      assert_unmerged_view(diff_buf)

      vim.api.nvim_set_option_value('modifiable', true, { buf = diff_buf })
      vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, { 'stale unmerged content' })
      vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })

      commands.read_buffer(diff_buf)

      assert_unmerged_view(diff_buf)
      helpers.delete_buffer(diff_buf)

      vim.api.nvim_set_current_win(source_win)
      commands.gdiff('++layout=stacked', false)

      local stacked_unmerged_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, stacked_unmerged_buf)
      assert_unmerged_view(stacked_unmerged_buf, 'single')

      vim.api.nvim_set_option_value('modifiable', true, { buf = stacked_unmerged_buf })
      vim.api.nvim_buf_set_lines(stacked_unmerged_buf, 0, -1, false, { 'stale unmerged content' })
      vim.api.nvim_set_option_value('modifiable', false, { buf = stacked_unmerged_buf })

      commands.read_buffer(stacked_unmerged_buf)

      assert_unmerged_view(stacked_unmerged_buf, 'single')
      helpers.delete_buffer(stacked_unmerged_buf)

      for _, object in ipairs({ ':%', ':0:%' }) do
        vim.api.nvim_set_current_win(source_win)
        commands.gdiff(object, false)

        local explicit_index_buf = vim.api.nvim_get_current_buf()
        table.insert(test_buffers, explicit_index_buf)
        assert_unmerged_view(explicit_index_buf)
        helpers.delete_buffer(explicit_index_buf)
      end

      vim.api.nvim_set_current_win(source_win)
      commands.gdiff('HEAD', false)

      local revision_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, revision_buf)
      local revision_text = buffer_text(revision_buf)

      assert.are.equal('diffs://HEAD:file.txt', vim.api.nvim_buf_get_name(revision_buf))
      assert.are.same(
        diffspec.rev_to_worktree('HEAD', 'file.txt'),
        vim.api.nvim_buf_get_var(revision_buf, 'diffs_spec')
      )
      assert.are.same({
        version = 1,
        kind = 'file',
        repo_root = repo_root,
        spec = diffspec.rev_to_worktree('HEAD', 'file.txt'),
      }, vim.api.nvim_buf_get_var(revision_buf, 'diffs_source'))
      assert.is_false(has_buf_var(revision_buf, 'diffs_unmerged'))
      assert.is_true(revision_text:find('+<<<<<<<', 1, true) ~= nil)
    end)
  end)

  describe('gdiff_file DiffSpec metadata', function()
    it('marks fugitive-style staged file diffs as HEAD to index buffers', function()
      mock_git_method('get_relative_path', function(filepath)
        if filepath == '/tmp/repo/lua/foo.lua' then
          return 'lua/foo.lua'
        end
        return nil
      end)
      mock_git_method('get_file_content', function(revision, filepath)
        assert.are.equal('HEAD', revision)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return { 'local M = {}', 'return M' }
      end)
      mock_git_method('get_index_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return { 'local M = {}', 'local x = 1', 'return M' }
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return '/tmp/repo'
      end)
      mock_runtime_attach(function() end)

      commands.gdiff_file('/tmp/repo/lua/foo.lua', { staged = true })

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)

      assert.are.equal('diffs://staged:lua/foo.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.head_to_index('lua/foo.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local diff_hunks = vim.api.nvim_buf_get_var(diff_buf, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('index', diff_hunks[1].mutation_target)
      assert.is_false(diff_hunks[1].can_put)
      assert.is_true(diff_hunks[1].can_obtain)
      assert.is_true(helpers.has_keymap(diff_buf, 'do'))
      assert.is_false(helpers.has_keymap(diff_buf, 'dp'))
    end)

    it('marks fugitive-style unstaged file diffs as index to worktree buffers', function()
      mock_git_method('get_relative_path', function(filepath)
        if filepath == '/tmp/repo/lua/foo.lua' then
          return 'lua/foo.lua'
        end
        return nil
      end)
      mock_git_method('get_index_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return { 'local M = {}', 'return M' }
      end)
      mock_git_method('get_working_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return { 'local M = {}', 'local x = 1', 'return M' }
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return '/tmp/repo'
      end)
      mock_runtime_attach(function() end)

      commands.gdiff_file('/tmp/repo/lua/foo.lua')

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)

      assert.are.equal('diffs://unstaged:lua/foo.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.index_to_worktree('lua/foo.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local diff_hunks = vim.api.nvim_buf_get_var(diff_buf, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('worktree', diff_hunks[1].mutation_target)
      assert.is_true(diff_hunks[1].can_put)
      assert.is_false(diff_hunks[1].can_obtain)
      assert.is_false(helpers.has_keymap(diff_buf, 'do'))
      assert.is_true(helpers.has_keymap(diff_buf, 'dp'))
    end)

    it('marks fugitive-style untracked file diffs as index to worktree buffers', function()
      mock_git_method('get_relative_path', function(filepath)
        if filepath == '/tmp/repo/lua/new.lua' then
          return 'lua/new.lua'
        end
        return nil
      end)
      mock_git_method('get_index_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return nil, 'file not in index'
      end)
      mock_git_method('get_working_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return { 'local M = {}', 'return M' }
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return '/tmp/repo'
      end)
      mock_runtime_attach(function() end)

      commands.gdiff_file('/tmp/repo/lua/new.lua', { untracked = true })

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)

      assert.are.equal('diffs://untracked:lua/new.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.index_to_worktree('lua/new.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local text = buffer_text(diff_buf)
      assert.is_true(text:find('new file mode 100644', 1, true) ~= nil)
      assert.is_true(text:find('--- /dev/null', 1, true) ~= nil)
      local diff_hunks = vim.api.nvim_buf_get_var(diff_buf, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('worktree', diff_hunks[1].mutation_target)
      assert.is_true(diff_hunks[1].can_put)
      assert.is_false(diff_hunks[1].can_obtain)
      assert.is_true(diff_hunks[1].actionable)
      assert.is_false(helpers.has_keymap(diff_buf, 'do'))
      assert.is_true(helpers.has_keymap(diff_buf, 'dp'))
    end)

    it('marks fugitive-style staged additions as HEAD to index buffers', function()
      mock_git_method('get_relative_path', function(filepath)
        if filepath == '/tmp/repo/lua/new.lua' then
          return 'lua/new.lua'
        end
        return nil
      end)
      mock_git_method('get_file_content', function(revision, filepath)
        assert.are.equal('HEAD', revision)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return nil, 'file not in revision: HEAD'
      end)
      mock_git_method('get_index_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return { 'local M = {}', 'return M' }
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/new.lua', filepath)
        return '/tmp/repo'
      end)
      mock_runtime_attach(function() end)

      commands.gdiff_file('/tmp/repo/lua/new.lua', { staged = true })

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)

      assert.are.equal('diffs://staged:lua/new.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.head_to_index('lua/new.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local text = buffer_text(diff_buf)
      assert.is_true(text:find('new file mode 100644', 1, true) ~= nil)
      assert.is_true(text:find('--- /dev/null', 1, true) ~= nil)
      local diff_hunks = vim.api.nvim_buf_get_var(diff_buf, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('index', diff_hunks[1].mutation_target)
      assert.is_false(diff_hunks[1].can_put)
      assert.is_true(diff_hunks[1].can_obtain)
      assert.is_true(diff_hunks[1].actionable)
      assert.is_true(helpers.has_keymap(diff_buf, 'do'))
      assert.is_false(helpers.has_keymap(diff_buf, 'dp'))
    end)

    it('marks fugitive-style staged deletions as HEAD to index buffers', function()
      mock_git_method('get_relative_path', function(filepath)
        if filepath == '/tmp/repo/lua/deleted.lua' then
          return 'lua/deleted.lua'
        end
        return nil
      end)
      mock_git_method('get_file_content', function(revision, filepath)
        assert.are.equal('HEAD', revision)
        assert.are.equal('/tmp/repo/lua/deleted.lua', filepath)
        return { 'local M = {}', 'return M' }
      end)
      mock_git_method('get_index_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/deleted.lua', filepath)
        return nil, 'file not in index'
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/deleted.lua', filepath)
        return '/tmp/repo'
      end)
      mock_runtime_attach(function() end)

      commands.gdiff_file('/tmp/repo/lua/deleted.lua', { staged = true })

      local diff_buf = vim.api.nvim_get_current_buf()
      table.insert(test_buffers, diff_buf)

      assert.are.equal('diffs://staged:lua/deleted.lua', vim.api.nvim_buf_get_name(diff_buf))
      assert.are.same(
        diffspec.head_to_index('lua/deleted.lua'),
        vim.api.nvim_buf_get_var(diff_buf, 'diffs_spec')
      )
      local text = buffer_text(diff_buf)
      assert.is_true(text:find('deleted file mode 100644', 1, true) ~= nil)
      assert.is_true(text:find('+++ /dev/null', 1, true) ~= nil)
      local diff_hunks = vim.api.nvim_buf_get_var(diff_buf, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('index', diff_hunks[1].mutation_target)
      assert.is_false(diff_hunks[1].can_put)
      assert.is_true(diff_hunks[1].can_obtain)
      assert.is_true(diff_hunks[1].actionable)
      assert.is_true(helpers.has_keymap(diff_buf, 'do'))
      assert.is_false(helpers.has_keymap(diff_buf, 'dp'))
    end)
  end)

  describe('generated buffer lifecycle matrix', function()
    local section_lines = {
      'diff --git a/lua/section.lua b/lua/section.lua',
      '--- a/lua/section.lua',
      '+++ b/lua/section.lua',
      '@@ -1 +1 @@',
      '-old section',
      '+new section',
    }

    local review_lines = {
      'diff --git a/lua/review.lua b/lua/review.lua',
      '--- a/lua/review.lua',
      '+++ b/lua/review.lua',
      '@@ -1 +1 @@',
      '-old review',
      '+new review',
    }

    local file_content = {
      ['/tmp/repo/lua/unstaged.lua'] = {
        index = { 'local M = {}', 'return M' },
        worktree = { 'local M = {}', 'local unstaged = true', 'return M' },
      },
      ['/tmp/repo/lua/staged.lua'] = {
        head = { 'local M = {}', 'return M' },
        index = { 'local M = {}', 'local staged = true', 'return M' },
      },
      ['/tmp/repo/lua/new.lua'] = {
        worktree = { 'local M = {}', 'local new_file = true', 'return M' },
      },
    }

    local function contains_cmd_arg(cmd, arg)
      for _, value in ipairs(cmd) do
        if value == arg then
          return true
        end
      end
      return false
    end

    local function install_lifecycle_mocks()
      mock_git_method('get_relative_path', function(filepath)
        return filepath:match('^/tmp/repo/(.+)$')
      end)
      mock_repo_root(function()
        return '/tmp/repo'
      end)
      mock_git_method('get_file_content', function(revision, filepath)
        local entry = file_content[filepath]
        if not entry or not entry.head then
          return nil, 'file not in revision: ' .. revision
        end
        return entry.head
      end)
      mock_git_method('get_index_content', function(filepath)
        local entry = file_content[filepath]
        if not entry or not entry.index then
          return nil, 'file not in index'
        end
        return entry.index
      end)
      mock_git_method('get_working_content', function(filepath)
        local entry = file_content[filepath]
        if not entry or not entry.worktree then
          return nil, 'file not readable'
        end
        return entry.worktree
      end)
      mock_git_method('get_tree_mode', function()
        return '100644'
      end)
      mock_git_method('get_index_mode', function(filepath)
        local entry = file_content[filepath]
        return entry and entry.index and '100644' or nil
      end)
      mock_git_method('get_working_mode', function(filepath)
        local entry = file_content[filepath]
        return entry and entry.worktree and '100644' or nil
      end)
      mock_systemlist(function(cmd)
        if cmd[4] == 'rev-parse' then
          return { 'commit' }
        end
        if cmd[4] == 'merge-base' then
          return { 'merge-base-commit' }
        end
        if
          contains_cmd_arg(cmd, '--name-status')
          or contains_cmd_arg(cmd, '--numstat')
          or contains_cmd_arg(cmd, '--raw')
        then
          return {}
        end
        if contains_cmd_arg(cmd, '--merge-base') then
          return review_lines
        end
        return section_lines
      end)
      mock_runtime_attach(function() end)
    end

    local function set_stale_content(bufnr)
      vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'stale lifecycle content' })
      vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
    end

    local function assert_generated_options(bufnr)
      assert.are.equal('nowrite', vim.api.nvim_get_option_value('buftype', { buf = bufnr }))
      assert.are.equal('delete', vim.api.nvim_get_option_value('bufhidden', { buf = bufnr }))
      assert.is_false(vim.api.nvim_get_option_value('swapfile', { buf = bufnr }))
      assert.is_false(vim.api.nvim_get_option_value('modifiable', { buf = bufnr }))
      assert.are.equal('diff', vim.api.nvim_get_option_value('filetype', { buf = bufnr }))
    end

    local function assert_no_hunk_maps(bufnr)
      assert.is_false(helpers.has_keymap(bufnr, ']c'))
      assert.is_false(helpers.has_keymap(bufnr, '[c'))
      assert.is_false(helpers.has_keymap(bufnr, '<CR>'))
      assert.is_false(helpers.has_keymap(bufnr, 'o'))
      assert.is_false(helpers.has_keymap(bufnr, 'do'))
      assert.is_false(helpers.has_keymap(bufnr, 'dp'))
      assert.is_false(helpers.has_keymap(bufnr, 'do', 'x'))
      assert.is_false(helpers.has_keymap(bufnr, 'dp', 'x'))
    end

    local function assert_hunk_maps(bufnr, hunk)
      assert.is_true(helpers.has_keymap(bufnr, ']c'))
      assert.is_true(helpers.has_keymap(bufnr, '[c'))
      assert.is_true(helpers.has_keymap(bufnr, '<CR>'))
      assert.is_false(helpers.has_keymap(bufnr, 'o'))
      assert.are.equal(hunk.can_obtain, helpers.has_keymap(bufnr, 'do'))
      assert.are.equal(hunk.can_put, helpers.has_keymap(bufnr, 'dp'))
      assert.are.equal(hunk.can_obtain, helpers.has_keymap(bufnr, 'do', 'x'))
      assert.are.equal(hunk.can_put, helpers.has_keymap(bufnr, 'dp', 'x'))
    end

    local function assert_lifecycle_state(bufnr, case)
      assert.are.equal(case.buffer_name, vim.api.nvim_buf_get_name(bufnr))
      assert.are.equal('/tmp/repo', vim.api.nvim_buf_get_var(bufnr, 'diffs_repo_root'))
      assert_generated_options(bufnr)

      if case.diff_spec then
        assert.are.same(case.diff_spec, vim.api.nvim_buf_get_var(bufnr, 'diffs_spec'))
      else
        assert.is_false(has_buf_var(bufnr, 'diffs_spec'))
      end

      assert.are.same(case.source, vim.api.nvim_buf_get_var(bufnr, 'diffs_source'))

      if case.review then
        assert.are.equal(case.review.base, vim.api.nvim_buf_get_var(bufnr, 'diffs_review_base'))
        assert.are.equal(case.review.target, vim.api.nvim_buf_get_var(bufnr, 'diffs_review_target'))
        assert.are.equal(case.review.mode, vim.api.nvim_buf_get_var(bufnr, 'diffs_review_mode'))
      end

      if case.hunk then
        local diff_hunks = vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')
        assert.are.equal(1, #diff_hunks)
        assert.are.equal(case.hunk.file, diff_hunks[1].file)
        assert.are.equal(case.hunk.mutation_target, diff_hunks[1].mutation_target)
        assert.are.equal(case.hunk.can_put, diff_hunks[1].can_put)
        assert.are.equal(case.hunk.can_obtain, diff_hunks[1].can_obtain)
        assert.are.equal(case.hunk.can_put or case.hunk.can_obtain, diff_hunks[1].actionable)
        assert_hunk_maps(bufnr, case.hunk)
      else
        assert.is_false(has_buf_var(bufnr, 'diffs_hunks'))
        assert_no_hunk_maps(bufnr)
      end

      local lines = buffer_lines(bufnr)
      assert.are.equal(case.first_line, lines[1])
      assert.is_false(vim.tbl_contains(lines, 'stale lifecycle content'))

      local qf = quickfix_items()
      assert.is_true(#qf >= 1, case.label)
      assert.are.equal(bufnr, qf[1].bufnr, case.label)
      assert.are.equal(1, qf[1].lnum, case.label)

      local loc = loclist_items()
      assert.is_true(#loc >= 1, case.label)
      assert.are.equal(bufnr, loc[1].bufnr, case.label)
      assert.is_true(loc[1].lnum > 1, case.label)
    end

    it('preserves generated buffer metadata and action keymaps across reloads', function()
      install_lifecycle_mocks()

      local cases = {
        {
          label = 'unstaged file',
          open = function()
            commands.gdiff_file('/tmp/repo/lua/unstaged.lua')
          end,
          buffer_name = 'diffs://unstaged:lua/unstaged.lua',
          diff_spec = diffspec.index_to_worktree('lua/unstaged.lua'),
          source = {
            version = 1,
            kind = 'file',
            repo_root = '/tmp/repo',
            spec = diffspec.index_to_worktree('lua/unstaged.lua'),
          },
          hunk = {
            file = 'lua/unstaged.lua',
            mutation_target = 'worktree',
            can_put = true,
            can_obtain = false,
          },
          first_line = 'diff --git a/lua/unstaged.lua b/lua/unstaged.lua',
        },
        {
          label = 'staged file',
          open = function()
            commands.gdiff_file('/tmp/repo/lua/staged.lua', { staged = true })
          end,
          buffer_name = 'diffs://staged:lua/staged.lua',
          diff_spec = diffspec.head_to_index('lua/staged.lua'),
          source = {
            version = 1,
            kind = 'file',
            repo_root = '/tmp/repo',
            spec = diffspec.head_to_index('lua/staged.lua'),
          },
          hunk = {
            file = 'lua/staged.lua',
            mutation_target = 'index',
            can_put = false,
            can_obtain = true,
          },
          first_line = 'diff --git a/lua/staged.lua b/lua/staged.lua',
        },
        {
          label = 'untracked file',
          open = function()
            commands.gdiff_file('/tmp/repo/lua/new.lua', { untracked = true })
          end,
          buffer_name = 'diffs://untracked:lua/new.lua',
          diff_spec = diffspec.index_to_worktree('lua/new.lua'),
          source = {
            version = 1,
            kind = 'file',
            repo_root = '/tmp/repo',
            spec = diffspec.index_to_worktree('lua/new.lua'),
          },
          hunk = {
            file = 'lua/new.lua',
            mutation_target = 'worktree',
            can_put = true,
            can_obtain = false,
          },
          first_line = 'diff --git a/lua/new.lua b/lua/new.lua',
        },
        {
          label = 'unstaged section',
          open = function()
            commands.gdiff_section('/tmp/repo')
          end,
          buffer_name = 'diffs://unstaged:all',
          source = {
            version = 1,
            kind = 'section',
            repo_root = '/tmp/repo',
            section = 'unstaged',
          },
          first_line = 'diff --git a/lua/section.lua b/lua/section.lua',
        },
        {
          label = 'review',
          open = function()
            commands.greview({
              base = 'origin/main',
              target = 'refs/forge/pr/42',
              mode = 'merge-base',
              repo = '/tmp/repo',
            })
          end,
          buffer_name = 'diffs://review:origin/main...refs/forge/pr/42',
          source = {
            version = 1,
            kind = 'review',
            repo_root = '/tmp/repo',
            review = {
              base = 'origin/main',
              target = 'refs/forge/pr/42',
              mode = 'merge-base',
            },
          },
          review = {
            base = 'origin/main',
            target = 'refs/forge/pr/42',
            mode = 'merge-base',
          },
          first_line = 'diff --git a/lua/review.lua b/lua/review.lua',
        },
      }

      for _, case in ipairs(cases) do
        case.open()
        local bufnr = vim.api.nvim_get_current_buf()
        table.insert(test_buffers, bufnr)

        assert_lifecycle_state(bufnr, case)
        set_stale_content(bufnr)

        assert.has_no.errors(function()
          commands.read_buffer(bufnr)
        end, case.label)
        assert_lifecycle_state(bufnr, case)
      end
    end)
  end)

  describe('setup registers Greview command', function()
    it('registers Greview command', function()
      commands.setup()
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Greview)
      assert.is_true(cmds.Greview.bar)
    end)
  end)

  describe('Greview helpers', function()
    it('parses base-only review args', function()
      local spec = commands._test.parse_review_arg('origin/main')
      assert.are.same({ base = 'origin/main' }, spec)
    end)

    it('parses merge-base review args', function()
      local spec = commands._test.parse_review_arg('origin/main...refs/pull/42/head')
      assert.are.same({
        base = 'origin/main',
        target = 'refs/pull/42/head',
        mode = 'merge-base',
      }, spec)
    end)

    it('parses direct review args', function()
      local spec = commands._test.parse_review_arg('origin/main..feature')
      assert.are.same({
        base = 'origin/main',
        target = 'feature',
        mode = 'direct',
      }, spec)
    end)

    it('parses Greview command layout options', function()
      local parsed =
        commands._test.parse_greview_command('++layout=split origin/main...refs/pull/42/head')

      assert.are.same({
        layout = 'split',
        spec = {
          base = 'origin/main',
          target = 'refs/pull/42/head',
          mode = 'merge-base',
        },
      }, parsed)
    end)

    it('parses Greview command stacked layout option', function()
      local parsed =
        commands._test.parse_greview_command('++layout=stacked origin/main...refs/pull/42/head')

      assert.are.same({
        layout = 'stacked',
        spec = {
          base = 'origin/main',
          target = 'refs/pull/42/head',
          mode = 'merge-base',
        },
      }, parsed)
    end)

    it('rejects unsupported Greview command layout options', function()
      local parsed, err = commands._test.parse_greview_command('++layout=tiled origin/main')

      assert.is_nil(parsed)
      assert.are.equal('unsupported layout tiled', err)
    end)

    it('rejects repeated Greview command layout options', function()
      local parsed, err =
        commands._test.parse_greview_command('++layout=split ++layout=unified origin/main')

      assert.is_nil(parsed)
      assert.are.equal('repeated ++layout option', err)
    end)

    it('treats non-layout plus-prefixed Greview args as review specs', function()
      local parsed, err = commands._test.parse_greview_command('++topic')

      assert.is_nil(err)
      assert.are.same({
        layout = 'unified',
        spec = { base = '++topic' },
      }, parsed)
    end)

    it('rejects multiple Greview command specs', function()
      local parsed, err = commands._test.parse_greview_command('origin/main feature/topic')

      assert.is_nil(parsed)
      assert.are.equal('expected at most one review spec', err)
    end)

    it('normalizes default base inside the resolved repo', function()
      local captured_cmds = {}
      mock_repo_root(function(path)
        assert.are.equal('/tmp/repo/.', path)
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        captured_cmds[#captured_cmds + 1] = cmd
        if cmd[4] == 'symbolic-ref' then
          return { 'refs/remotes/origin/main' }
        end
        if cmd[4] == 'rev-parse' then
          return { 'commit' }
        end
        return {}
      end)

      local review = commands._test.normalize_greview({ repo = '/tmp/repo' })

      assert.are.equal('/tmp/repo', review.repo_root)
      assert.are.equal('origin/main', review.base)
      assert.are.equal('origin/main', review.display)
      assert.are.same(
        { 'git', '-C', '/tmp/repo', 'symbolic-ref', 'refs/remotes/origin/HEAD' },
        captured_cmds[1]
      )
      assert.are.same(
        { 'git', '-C', '/tmp/repo', 'rev-parse', '--verify', '--quiet', 'origin/main^{commit}' },
        captured_cmds[2]
      )
    end)

    it('completes target refs after merge-base separator', function()
      mock_repo_root(function()
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        assert.are.same({
          'git',
          '-C',
          '/tmp/repo',
          'for-each-ref',
          '--format=%(refname:short)',
          'refs/heads/',
          'refs/remotes/',
          'refs/tags/',
        }, cmd)
        return { 'origin/main', 'refs/forge/pr/42', 'refs/forge/pr/43' }
      end)

      local matches = commands._test.complete_greview('origin/main...refs/forge/pr/4')

      assert.are.same({
        'origin/main...refs/forge/pr/42',
        'origin/main...refs/forge/pr/43',
      }, matches)
    end)

    it('completes target refs after direct separator', function()
      mock_repo_root(function()
        return '/tmp/repo'
      end)
      mock_systemlist(function()
        return { 'origin/main', 'feature/a', 'feature/b' }
      end)

      local matches = commands._test.complete_greview('origin/main..feature/')

      assert.are.same({ 'origin/main..feature/a', 'origin/main..feature/b' }, matches)
    end)

    it('completes Greview command layout options', function()
      local matches = commands._test.complete_greview_command('++l')

      assert.are.same({
        '++layout=unified',
        '++layout=stacked',
        '++layout=split',
      }, matches)
    end)

    it('completes Greview layout options only before a review spec', function()
      mock_repo_root(function()
        return '/tmp/repo'
      end)
      mock_systemlist(function()
        return { 'origin/main', 'feature/topic', '++topic' }
      end)

      assert.are.same({
        '++layout=unified',
        '++layout=stacked',
        '++layout=split',
        'origin/main',
        'feature/topic',
        '++topic',
      }, commands._test.complete_greview_command('', 'Greview ', #'Greview '))
      assert.are.same(
        {
          'origin/main',
          'feature/topic',
          '++topic',
        },
        commands._test.complete_greview_command(
          '',
          'Greview ++layout=split ',
          #'Greview ++layout=split '
        )
      )
      assert.are.same(
        {},
        commands._test.complete_greview_command('', 'Greview origin/main ', #'Greview origin/main ')
      )
      assert.are.same(
        { 'origin/main' },
        commands._test.complete_greview_command('origin/', 'Greview origin/', #'Greview origin/')
      )
      assert.are.same(
        { 'origin/main' },
        commands._test.complete_greview_command(
          'origin/',
          'belowright Greview origin/',
          #'belowright Greview origin/'
        )
      )
      assert.are.same({
        '++layout=unified',
        '++layout=stacked',
        '++layout=split',
        '++topic',
      }, commands._test.complete_greview_command('++', 'Greview ++', #'Greview ++'))
      assert.are.same(
        { '++topic' },
        commands._test.complete_greview_command(
          '++',
          'Greview ++layout=split ++',
          #'Greview ++layout=split ++'
        )
      )
    end)
  end)

  describe('greview', function()
    it('reports a missing base ref before rendering', function()
      local called_diff = false
      local notifications = capture_notifications()
      mock_repo_root(function(path)
        assert.are.equal('/tmp/repo/.', path)
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        if cmd[4] == 'diff' then
          called_diff = true
        end
        if cmd[4] == 'rev-parse' then
          return {}, 1
        end
        return {}
      end)

      local bufnr = commands.greview({
        base = 'missing/ref',
        repo = '/tmp/repo',
      })

      assert.is_nil(bufnr)
      assert.is_false(called_diff)
      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
      assert.is_true(
        notifications[#notifications].message:find(
          'Greview base ref not found: missing/ref (spec: missing/ref)',
          1,
          true
        ) ~= nil
      )
    end)

    it('reports a missing target ref before rendering', function()
      local called_diff = false
      local called_merge_base = false
      local notifications = capture_notifications()
      mock_repo_root(function(path)
        assert.are.equal('/tmp/repo/.', path)
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        if cmd[4] == 'diff' then
          called_diff = true
        elseif cmd[4] == 'merge-base' then
          called_merge_base = true
        elseif cmd[4] == 'rev-parse' and cmd[7] == 'missing/target^{commit}' then
          return {}, 1
        end
        return {}
      end)

      local bufnr = commands.greview({
        base = 'HEAD',
        target = 'missing/target',
        mode = 'merge-base',
        repo = '/tmp/repo',
      })

      assert.is_nil(bufnr)
      assert.is_false(called_diff)
      assert.is_false(called_merge_base)
      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
      assert.is_true(
        notifications[#notifications].message:find(
          'Greview target ref not found: missing/target (spec: HEAD...missing/target)',
          1,
          true
        ) ~= nil
      )
    end)

    it('reports a missing merge base before rendering merge-base reviews', function()
      local called_diff = false
      local notifications = capture_notifications()
      mock_repo_root(function(path)
        assert.are.equal('/tmp/repo/.', path)
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        if cmd[4] == 'diff' then
          called_diff = true
        elseif cmd[4] == 'merge-base' then
          return {}, 1
        end
        return {}
      end)

      local bufnr = commands.greview({
        base = 'HEAD',
        target = 'other',
        mode = 'merge-base',
        repo = '/tmp/repo',
      })

      assert.is_nil(bufnr)
      assert.is_false(called_diff)
      assert.are.equal(vim.log.levels.ERROR, notifications[#notifications].level)
      assert.is_true(
        notifications[#notifications].message:find(
          'Greview merge base not found for spec: HEAD...other',
          1,
          true
        ) ~= nil
      )
    end)

    it('opens a review buffer for an explicit merge-base target', function()
      local captured_cmd
      mock_repo_root(function(path)
        assert.are.equal('/tmp/repo/.', path)
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        if cmd[4] == 'rev-parse' then
          return { 'commit' }
        end
        if cmd[4] == 'merge-base' then
          return { 'merge-base-commit' }
        end
        if cmd[4] ~= 'diff' then
          return {}
        end
        captured_cmd = cmd
        return {
          'diff --git a/file.lua b/file.lua',
          '--- a/file.lua',
          '+++ b/file.lua',
          '@@ -1 +1 @@',
          '-old',
          '+new',
        }
      end)
      mock_runtime_attach(function() end)

      local bufnr = commands.greview({
        base = 'origin/main',
        target = 'refs/forge/pr/42',
        mode = 'merge-base',
        repo = '/tmp/repo',
      })
      table.insert(test_buffers, bufnr)

      assert.are.same({
        'git',
        '-C',
        '/tmp/repo',
        'diff',
        '--no-ext-diff',
        '--no-color',
        '--merge-base',
        'origin/main',
        'refs/forge/pr/42',
      }, captured_cmd)
      assert.are.equal(
        'diffs://review:origin/main...refs/forge/pr/42',
        vim.api.nvim_buf_get_name(bufnr)
      )
      assert.are.equal('origin/main', vim.api.nvim_buf_get_var(bufnr, 'diffs_review_base'))
      assert.are.equal('refs/forge/pr/42', vim.api.nvim_buf_get_var(bufnr, 'diffs_review_target'))
      assert.are.equal('merge-base', vim.api.nvim_buf_get_var(bufnr, 'diffs_review_mode'))
    end)

    it('initializes generated review metadata before diff FileType attach', function()
      local attach_records = {}
      saved_schedule = vim.schedule
      vim.schedule = function(callback)
        callback()
      end

      local group = vim.api.nvim_create_augroup('DiffsGeneratedReviewFileTypeRegression', {
        clear = true,
      })
      vim.api.nvim_create_autocmd('FileType', {
        pattern = 'diff',
        group = group,
        callback = function(args)
          runtime.attach(args.buf)
          local rail_ok, rail_width = pcall(vim.api.nvim_buf_get_var, args.buf, 'diffs_rail_width')
          local entry = runtime._test.hunk_cache[args.buf]
          attach_records[#attach_records + 1] = {
            name = vim.api.nvim_buf_get_name(args.buf),
            rail_width = rail_ok and rail_width or nil,
            hunk_count = entry and #entry.hunks or nil,
          }
        end,
      })

      local repo = create_review_repo({ named_refs = true })
      local ok, bufnr = pcall(function()
        return commands.greview({
          base = repo.base,
          target = repo.target,
          mode = 'merge-base',
          repo = repo.repo_root,
        })
      end)
      pcall(vim.api.nvim_del_augroup_by_id, group)

      assert.is_true(ok)
      assert.is_not_nil(bufnr)
      table.insert(test_buffers, bufnr)

      local first_attach = attach_records[1]
      assert.is_not_nil(first_attach)
      assert.are.equal('diffs://review:review-base...review-topic', first_attach.name)
      assert.is_number(first_attach.rail_width)
      assert.is_true(first_attach.rail_width > 0)
      assert.is_number(first_attach.hunk_count)
      assert.is_true(first_attach.hunk_count > 0)
    end)

    it('renders current-state reviews as stacked sections', function()
      local repo = create_current_state_review_repo()
      mock_runtime_attach(function() end)

      local bufnr = commands.greview({
        base = repo.base,
        repo = repo.repo_root,
      })
      assert.is_not_nil(bufnr)
      table.insert(test_buffers, bufnr)

      local text = buffer_text(bufnr)
      assert.is_true(text:find('# Branch:', 1, true) ~= nil)
      assert.is_true(text:find('# Staged:', 1, true) ~= nil)
      assert.is_true(text:find('# Unstaged:', 1, true) ~= nil)
      assert.is_true(text:find('# Untracked:', 1, true) ~= nil)
      assert.is_true(text:find('+branch head', 1, true) ~= nil)
      assert.is_true(text:find('+dup staged', 1, true) ~= nil)
      assert.is_true(text:find('+dup unstaged', 1, true) ~= nil)
      assert.is_true(text:find('+new file', 1, true) ~= nil)

      local qf = quickfix_items()
      assert.are.equal(7, #qf)
      assert.is_true(qf[1].text:find('[Branch] lua/branch.lua', 1, true) ~= nil)
      assert.is_true(qf[2].text:find('[Branch] lua/dup.lua', 1, true) ~= nil)
      assert.is_true(qf[3].text:find('[Staged] lua/dup.lua', 1, true) ~= nil)
      assert.is_true(qf[4].text:find('[Staged] lua/staged.lua', 1, true) ~= nil)
      assert.is_true(qf[5].text:find('[Unstaged] lua/dup.lua', 1, true) ~= nil)
      assert.is_true(qf[6].text:find('[Unstaged] lua/unstaged.lua', 1, true) ~= nil)
      assert.is_true(qf[7].text:find('[Untracked] lua/new.lua', 1, true) ~= nil)

      assert.are.equal('branch:lua/dup.lua', qf[2].user_data.diffs.key)
      assert.are.equal('staged:lua/dup.lua', qf[3].user_data.diffs.key)
      assert.are.equal('unstaged:lua/dup.lua', qf[5].user_data.diffs.key)
    end)

    it('opens Greview stacked layout as a single generated review map with single rails', function()
      local repo = create_current_state_review_repo()
      edit_file(repo.repo_root .. '/lua/branch.lua')
      mock_runtime_attach(function() end)
      mock_view_config({ prefix = true, change_bar = '▏', rail_separator = '|' })

      local bufnr = commands.greview_command(('++layout=stacked %s'):format(repo.base))
      assert.is_not_nil(bufnr)
      table.insert(test_buffers, bufnr)

      local display_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = buffer_text(bufnr)

      assert.are.equal('diffs://review:' .. repo.base, vim.api.nvim_buf_get_name(bufnr))
      assert.are.equal('single', vim.api.nvim_buf_get_var(bufnr, 'diffs_rail_style'))
      assert.are.equal('single', rails.style_for_buffer(bufnr))
      assert.is_true(display_lines[1]:find('    | # Branch:', 1, true) ~= nil)
      assert.is_true(text:find('# Branch:', 1, true) ~= nil)
      assert.is_true(text:find('# Staged:', 1, true) ~= nil)
      assert.is_true(text:find('# Unstaged:', 1, true) ~= nil)
      assert.is_true(text:find('# Untracked:', 1, true) ~= nil)
      assert.is_true(text:find('+branch head', 1, true) ~= nil)
      assert.is_nil(commands._test.review_split_state(bufnr))

      local qf = quickfix_items()
      assert.are.equal(7, #qf)
      assert.are.equal(bufnr, qf[1].bufnr)
      assert.are.equal('branch:lua/branch.lua', qf[1].user_data.diffs.key)
      assert.are.equal('staged:lua/dup.lua', qf[3].user_data.diffs.key)
      assert.are.equal('unstaged:lua/dup.lua', qf[5].user_data.diffs.key)

      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        assert.is_false(name:match('^diffs://review%-split:') ~= nil)
        assert.is_false(name:match('^diffs://review%-target:') ~= nil)
      end
    end)

    local function main_windows()
      local wins = {}
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local buf = vim.api.nvim_win_get_buf(win)
        if vim.api.nvim_get_option_value('buftype', { buf = buf }) ~= 'quickfix' then
          wins[#wins + 1] = win
        end
      end
      return wins
    end

    local function visible_review_map()
      for _, win in ipairs(main_windows()) do
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        if name:match('^diffs://review:') then
          return win
        end
      end
      return nil
    end

    local function track_panes(left_buf)
      assert.is_not_nil(left_buf)
      table.insert(test_buffers, left_buf)
      local right_buf = vim.api.nvim_buf_get_var(left_buf, 'diffs_split_peer')
      table.insert(test_buffers, right_buf)
      local state = commands._test.review_split_state(left_buf)
      assert.is_not_nil(state)
      assert.are.equal(left_buf, state.left_buf)
      assert.are.equal(right_buf, state.right_buf)
      return {
        state = state,
        left_buf = left_buf,
        right_buf = right_buf,
        left_win = state.left_win,
        right_win = state.right_win,
      }
    end

    local function run_buf_keymap(bufnr, lhs)
      for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
        if keymap.lhs == lhs and keymap.callback then
          keymap.callback()
          return
        end
      end
      error('missing buffer keymap: ' .. lhs)
    end

    local function assert_target_at_hunk(panes, hunk_index)
      local hunks = vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_split_hunks')
      local hunk = hunks[hunk_index]
      assert.is_not_nil(hunk)
      assert.are.same(
        { math.max(1, hunk.new_range.start), 0 },
        vim.api.nvim_win_get_cursor(panes.right_win)
      )
      assert.are.same(
        { math.max(1, hunk.old_range.start), 0 },
        vim.api.nvim_win_get_cursor(panes.left_win)
      )
    end

    local function create_mode_first_review_repo()
      local repo_root = vim.fn.tempname()
      vim.fn.mkdir(repo_root, 'p')
      test_repos[#test_repos + 1] = repo_root

      vim.fn.systemlist({ 'git', 'init', '-q', repo_root })
      assert.are.equal(0, vim.v.shell_error)
      git_cmd(repo_root, { 'config', 'user.email', 'test@example.com' })
      git_cmd(repo_root, { 'config', 'user.name', 'Test' })
      git_cmd(repo_root, { 'config', 'core.filemode', 'true' })

      write_repo_file(repo_root, 'aaa-mode.sh', { '#!/bin/sh', 'echo mode' })
      write_repo_file(repo_root, 'zzz-changed.lua', { 'old' })
      git_cmd(repo_root, { 'add', 'aaa-mode.sh', 'zzz-changed.lua' })
      git_cmd(repo_root, { 'commit', '-qm', 'base' })
      git_cmd(repo_root, { 'branch', 'mode-base' })

      git_cmd(repo_root, { 'checkout', '-qb', 'mode-topic' })
      git_cmd(repo_root, { 'update-index', '--chmod=+x', 'aaa-mode.sh' })
      write_repo_file(repo_root, 'zzz-changed.lua', { 'new' })
      git_cmd(repo_root, { 'add', 'aaa-mode.sh', 'zzz-changed.lua' })
      git_cmd(repo_root, { 'commit', '-qm', 'mode and content' })

      return repo_root
    end

    it('opens Greview layout split as exactly two visible surfaces', function()
      local repo_root = create_repo()
      vim.fn.writefile({ 'line 1', 'line 2 changed' }, repo_root .. '/file.txt')
      edit_file(repo_root .. '/file.txt')
      mock_runtime_attach(function() end)

      local left_buf = commands.greview_command('++layout=split HEAD')
      local panes = track_panes(left_buf)

      assert.are.equal(
        'diffs://split:left:index:file.txt',
        vim.api.nvim_buf_get_name(panes.left_buf)
      )
      assert.are.equal(
        'diffs://split:right:worktree:file.txt',
        vim.api.nvim_buf_get_name(panes.right_buf)
      )
      assert.are.same(
        diffspec.index_to_worktree('file.txt'),
        vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_spec')
      )
      assert.are.same(
        diffspec.index_to_worktree('file.txt'),
        vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_spec')
      )
      assert.are.equal('left', vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_split_side'))
      assert.are.equal('right', vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_split_side'))
      assert.are.same(
        { 'line 1', 'line 2' },
        vim.api.nvim_buf_get_lines(panes.left_buf, 0, -1, false)
      )
      assert.are.same(
        { 'line 1', 'line 2 changed' },
        vim.api.nvim_buf_get_lines(panes.right_buf, 0, -1, false)
      )
      assert.are.equal(2, #main_windows())
      assert.is_nil(visible_review_map())
      assert.is_true(vim.api.nvim_get_option_value('diff', { win = panes.left_win }))
      assert.is_true(vim.api.nvim_get_option_value('diff', { win = panes.right_win }))
      assert.is_true(vim.api.nvim_get_option_value('scrollbind', { win = panes.left_win }))
      assert.is_true(vim.api.nvim_get_option_value('scrollbind', { win = panes.right_win }))

      local qf = quickfix_items()
      assert.are.equal(1, #qf)
      assert.are.equal(panes.left_buf, qf[1].bufnr)
      assert.is_true(qf[1].text:find('file.txt', 1, true) ~= nil)

      local loc = loclist_items(panes.left_win)
      assert.are.equal(1, #loc)
      assert.are.equal(panes.left_buf, loc[1].bufnr)
      assert.is_true(loc[1].text:find('file.txt', 1, true) ~= nil)
    end)

    it('warns and still opens the workspace for :vertical Diff review ++layout=split', function()
      local repo_root = create_repo()
      vim.fn.writefile({ 'line 1', 'line 2 changed' }, repo_root .. '/file.txt')
      edit_file(repo_root .. '/file.txt')
      mock_runtime_attach(function() end)
      local notifications = capture_notifications()

      local left_buf =
        commands.greview_command('++layout=split HEAD', true, { warn_vertical_split = true })
      track_panes(left_buf)

      local warned = false
      for _, n in ipairs(notifications) do
        if tostring(n.message):find('++layout=split ignores the :vertical modifier', 1, true) then
          warned = true
        end
      end
      assert.is_true(warned)
      assert.are.equal(2, #main_windows())
    end)

    it('replaces the visible review buffer even when another window is current', function()
      local repo = create_review_repo()
      mock_runtime_attach(function() end)

      local review_buf = commands.greview({
        base = repo.base,
        target = repo.target,
        mode = 'direct',
        repo = repo.repo_root,
      })
      assert.is_not_nil(review_buf)
      table.insert(test_buffers, review_buf)
      local review_win = find_window_for_buffer(review_buf)
      assert.is_not_nil(review_win)

      vim.cmd('rightbelow vsplit')
      local source_buf = edit_file(repo.repo_root .. '/lua/one.lua')
      local source_win = vim.api.nvim_get_current_win()

      local left_buf = commands.greview_split({ bufnr = review_buf })
      local panes = track_panes(left_buf)

      assert.are.equal(review_win, panes.left_win)
      assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source_win))
      assert.is_nil(find_window_for_buffer(review_buf))
      assert.is_not_nil(find_window_for_buffer(panes.left_buf))
      assert.is_not_nil(find_window_for_buffer(panes.right_buf))
    end)

    it('warns instead of splitting when the selected review buffer is hidden', function()
      local repo = create_review_repo()
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      local review_buf = commands.greview({
        base = repo.base,
        target = repo.target,
        mode = 'direct',
        repo = repo.repo_root,
      })
      assert.is_not_nil(review_buf)
      table.insert(test_buffers, review_buf)
      vim.api.nvim_set_option_value('bufhidden', 'hide', { buf = review_buf })

      local source_buf = edit_file(repo.repo_root .. '/lua/one.lua')
      local source_win = vim.api.nvim_get_current_win()

      local opened = commands.greview_split({ bufnr = review_buf })

      assert.is_nil(opened)
      assert.are.equal(source_buf, vim.api.nvim_win_get_buf(source_win))
      assert.is_true(
        notifications[#notifications].message:find(
          'selected Greview buffer is not visible',
          1,
          true
        ) ~= nil
      )
    end)

    it('closes an existing Greview split workspace before opening another spec', function()
      local repo = create_review_repo()
      mock_repo_root(function()
        return repo.repo_root
      end)
      mock_runtime_attach(function() end)

      local first =
        commands.greview_command(('++layout=split %s..%s'):format(repo.base, repo.target))
      local first_panes = track_panes(first)
      local first_left = first_panes.left_buf
      local first_right = first_panes.right_buf

      local second =
        commands.greview_command(('++layout=split %s...%s'):format(repo.base, repo.target))
      local second_panes = track_panes(second)

      assert.is_false(vim.api.nvim_buf_is_valid(first_left))
      assert.is_false(vim.api.nvim_buf_is_valid(first_right))
      assert.is_nil(commands._test.review_split_state(first_left))
      assert.is_not_nil(commands._test.review_split_state(second))
      assert.are.equal(2, #main_windows())
      assert.is_not_nil(find_window_for_buffer(second_panes.left_buf))
      assert.is_not_nil(find_window_for_buffer(second_panes.right_buf))
    end)

    it('skips unsupported default review entries when opening direct split workspaces', function()
      local repo_root = create_mode_first_review_repo()
      edit_file(repo_root .. '/zzz-changed.lua')
      mock_runtime_attach(function() end)

      local left_buf = commands.greview_command('++layout=split mode-base..mode-topic')
      local panes = track_panes(left_buf)

      assert.are.same(
        diffspec.rev_to_rev('mode-base', 'mode-topic', 'zzz-changed.lua'),
        vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_spec')
      )
      assert.are.same(
        diffspec.rev_to_rev('mode-base', 'mode-topic', 'zzz-changed.lua'),
        vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_spec')
      )
      assert.are.same({ 'old' }, vim.api.nvim_buf_get_lines(panes.left_buf, 0, -1, false))
      assert.are.same({ 'new' }, vim.api.nvim_buf_get_lines(panes.right_buf, 0, -1, false))
    end)

    it('routes current-state duplicate paths by section in the two-surface workspace', function()
      local repo = create_current_state_review_repo()
      mock_runtime_attach(function() end)

      local function open_section(header, expected_spec)
        local review_buf = commands.greview({
          base = repo.base,
          repo = repo.repo_root,
        })
        assert.is_not_nil(review_buf)
        table.insert(test_buffers, review_buf)

        local line =
          find_buffer_line_after(review_buf, header, 'diff --git a/lua/dup.lua b/lua/dup.lua')
        assert.is_not_nil(line)
        vim.api.nvim_win_set_cursor(0, { line, 0 })

        local left_buf = commands.greview_split({ bufnr = review_buf })
        local panes = track_panes(left_buf)
        assert.are.same(expected_spec, vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_spec'))
        assert.are.same(expected_spec, vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_spec'))
        assert.is_not_nil(find_window_for_buffer(panes.left_buf))
        assert.is_not_nil(find_window_for_buffer(panes.right_buf))
        assert.is_nil(find_window_for_buffer(review_buf))
        assert.is_nil(visible_review_map())
        split.close_pair(panes.left_buf)
      end

      open_section('# Branch:', diffspec.rev_to_rev(repo.base, 'HEAD', 'lua/dup.lua'))
      open_section('# Staged:', diffspec.head_to_index('lua/dup.lua'))
      open_section('# Unstaged:', diffspec.index_to_worktree('lua/dup.lua'))
    end)

    it('uses quickfix for review files and loclist for active-file hunks', function()
      local repo = create_review_repo()
      edit_file(repo.repo_root .. '/lua/one.lua')
      mock_runtime_attach(function() end)

      local left_buf =
        commands.greview_command(('++layout=split %s..%s'):format(repo.base, repo.target))
      local panes = track_panes(left_buf)
      assert.are.same(
        diffspec.rev_to_rev(repo.base, repo.target, 'lua/one.lua'),
        vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_spec')
      )

      local qf = quickfix_items()
      assert.are.equal(2, #qf)
      assert.are.equal(panes.left_buf, qf[1].bufnr)
      assert.are.equal(panes.left_buf, qf[2].bufnr)

      vim.cmd('copen')
      local qf_win = find_quickfix_window()
      assert.is_not_nil(qf_win)
      vim.api.nvim_set_current_win(qf_win)
      vim.api.nvim_win_set_cursor(qf_win, { 2, 0 })
      vim.cmd('normal \r')

      vim.wait(100, function()
        return panes.state.selected_file == 'lua/two.lua'
      end)

      panes = track_panes(panes.state.left_buf)
      assert.are.same(
        diffspec.rev_to_rev(repo.base, repo.target, 'lua/two.lua'),
        vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_spec')
      )
      assert.are.same(
        diffspec.rev_to_rev(repo.base, repo.target, 'lua/two.lua'),
        vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_spec')
      )
      assert.is_true(buffer_text(panes.right_buf):find('line 11 changed', 1, true) ~= nil)

      local new_qf = quickfix_items()
      assert.are.equal(2, #new_qf)
      assert.are.equal(panes.left_buf, new_qf[1].bufnr)
      assert.are.equal(panes.left_buf, new_qf[2].bufnr)

      assert_target_at_hunk(panes, 1)

      vim.api.nvim_set_current_win(panes.left_win)
      vim.cmd('lopen')
      local loc_win = find_loclist_window_for_window(panes.left_win)
      assert.is_not_nil(loc_win)
      local loc = loclist_items(panes.left_win)
      assert.are.equal(2, #loc)
      assert.are.equal(panes.left_buf, loc[1].bufnr)
      local rloc = loclist_items(panes.right_win)
      assert.are.equal(2, #rloc)
      assert.are.equal(panes.right_buf, rloc[1].bufnr)
      vim.cmd('lclose')

      vim.api.nvim_set_current_win(panes.right_win)
      run_buf_keymap(panes.right_buf, ']c')
      assert_target_at_hunk(panes, 2)
      run_buf_keymap(panes.right_buf, '[c')
      assert_target_at_hunk(panes, 1)
    end)

    it('navigates loclist hunks without switching the active review file', function()
      local repo = create_review_repo()
      edit_file(repo.repo_root .. '/lua/one.lua')
      mock_runtime_attach(function() end)

      local left_buf =
        commands.greview_command(('++layout=split %s..%s'):format(repo.base, repo.target))
      local panes = track_panes(left_buf)
      assert.are.equal('lua/one.lua', panes.state.selected_file)

      vim.api.nvim_set_current_win(panes.left_win)
      vim.cmd('lopen')
      local loc_win = find_loclist_window_for_window(panes.left_win)
      assert.is_not_nil(loc_win)
      local loc = loclist_items(panes.left_win)
      assert.is_true(#loc >= 1)

      vim.api.nvim_set_current_win(loc_win)
      vim.api.nvim_win_set_cursor(loc_win, { #loc, 0 })
      local ok = pcall(function()
        vim.cmd('normal \r')
      end)
      vim.wait(50)

      assert.is_true(ok)
      assert.are.equal('lua/one.lua', panes.state.selected_file)
      assert.is_true(vim.api.nvim_buf_is_valid(panes.left_buf))
      assert.is_true(vim.api.nvim_buf_is_valid(panes.right_buf))
    end)

    it('closes both Greview split surfaces from the generated diff buffer', function()
      local repo_root = create_repo()
      vim.fn.writefile({ 'line 1', 'line 2 changed' }, repo_root .. '/file.txt')
      edit_file(repo_root .. '/file.txt')
      mock_runtime_attach(function() end)

      local left_buf = commands.greview_command('++layout=split HEAD')
      local panes = track_panes(left_buf)

      vim.api.nvim_set_current_win(panes.right_win)
      run_buf_keymap(panes.right_buf, 'q')

      assert.is_false(vim.api.nvim_buf_is_valid(panes.left_buf))
      assert.is_false(vim.api.nvim_buf_is_valid(panes.right_buf))
      assert.is_nil(commands._test.review_split_state(panes.left_buf))
      assert.is_nil(commands._test.review_split_state(panes.right_buf))
    end)

    it('skips binary untracked files in current-state reviews', function()
      local repo_root = create_repo()
      write_repo_file(repo_root, 'lua/new.lua', { 'new text' })
      write_binary_file(repo_root .. '/bin.dat', 'binary\\000new')
      mock_runtime_attach(function() end)

      local bufnr = commands.greview({
        base = 'HEAD',
        repo = repo_root,
      })
      assert.is_not_nil(bufnr)
      table.insert(test_buffers, bufnr)

      local text = buffer_text(bufnr)
      assert.is_true(text:find('# Untracked:', 1, true) ~= nil)
      assert.is_true(text:find('diff --git a/lua/new.lua b/lua/new.lua', 1, true) ~= nil)
      assert.is_true(text:find('+new text', 1, true) ~= nil)
      assert.is_false(text:find('bin.dat', 1, true) ~= nil)

      local qf = quickfix_items()
      assert.are.equal(1, #qf)
      assert.is_true(qf[1].text:find('[Untracked] lua/new.lua', 1, true) ~= nil)
    end)

    it('routes current-state conflict reviews to read-only unmerged target views', function()
      local repo_root = create_conflicted_repo()
      mock_runtime_attach(function() end)

      local bufnr = commands.greview({
        base = 'HEAD',
        repo = repo_root,
      })
      assert.is_not_nil(bufnr)
      table.insert(test_buffers, bufnr)

      local text = buffer_text(bufnr)
      assert.is_false(text:find('# Staged:', 1, true) ~= nil)
      assert.is_true(text:find('# Unstaged:', 1, true) ~= nil)
      assert.is_true(text:find('-line 2 theirs', 1, true) ~= nil)
      assert.is_true(text:find('+line 2 ours', 1, true) ~= nil)

      local qf = quickfix_items()
      assert.are.equal(1, #qf)
      assert.are.equal('unstaged', qf[1].user_data.diffs.section)
      assert.are.same(diffspec.rev_to_rev(':2', ':3', 'file.txt'), qf[1].user_data.diffs.diff_spec)

      local header_line = find_buffer_line(bufnr, '# Unstaged:')
      assert.is_not_nil(header_line)
      vim.api.nvim_win_set_cursor(0, { header_line, 0 })
      local left_buf = commands.greview_split({ bufnr = bufnr })
      local panes = track_panes(left_buf)

      assert.are.same(
        diffspec.rev_to_rev(':2', ':3', 'file.txt'),
        vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_spec')
      )
      assert.are.same(
        diffspec.rev_to_rev(':2', ':3', 'file.txt'),
        vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_spec')
      )
      assert.is_true(buffer_text(panes.left_buf):find('line 2 theirs', 1, true) ~= nil)
      assert.is_true(buffer_text(panes.right_buf):find('line 2 ours', 1, true) ~= nil)
    end)

    it('opens a base-only current-state review file as the selected section edge', function()
      local repo = create_review_repo({ commit_target = false })
      edit_file(repo.repo_root .. '/lua/two.lua')
      mock_runtime_attach(function() end)

      local left_buf = commands.greview_command(('++layout=split %s'):format(repo.base))
      local panes = track_panes(left_buf)

      assert.are.same(
        diffspec.index_to_worktree('lua/one.lua'),
        vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_spec')
      )
      assert.are.same(
        diffspec.index_to_worktree('lua/one.lua'),
        vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_spec')
      )
    end)

    it('opens a merge-base review file from the resolved merge base to the target tree', function()
      local repo = create_review_repo({ named_refs = true })
      edit_file(repo.repo_root .. '/lua/one.lua')
      mock_runtime_attach(function() end)

      local left_buf =
        commands.greview_command(('++layout=split %s...%s'):format(repo.base, repo.target))
      local panes = track_panes(left_buf)

      assert.are.same(
        diffspec.rev_to_rev(repo.base_sha, repo.target, 'lua/one.lua'),
        vim.api.nvim_buf_get_var(panes.left_buf, 'diffs_spec')
      )
      assert.are.same(
        diffspec.rev_to_rev(repo.base_sha, repo.target, 'lua/one.lua'),
        vim.api.nvim_buf_get_var(panes.right_buf, 'diffs_spec')
      )
    end)

    it('reports unsupported selected review files without opening a workspace', function()
      local repo = create_mode_only_review_repo()
      local notifications = capture_notifications()
      mock_runtime_attach(function() end)

      local bufnr = commands.greview({
        base = repo.base,
        target = repo.target,
        mode = 'direct',
        repo = repo.repo_root,
      })
      assert.is_not_nil(bufnr)
      table.insert(test_buffers, bufnr)

      local mode_line = find_buffer_line(bufnr, 'diff --git a/scripts/tool.sh b/scripts/tool.sh')
      assert.is_not_nil(mode_line)
      vim.api.nvim_win_set_cursor(0, { mode_line, 0 })

      local opened = commands.greview_split({ bufnr = bufnr })

      assert.is_nil(opened)
      assert.is_true(
        notifications[#notifications].message:find('mode-only changes', 1, true) ~= nil
      )
      assert.is_nil(commands._test.review_split_state(bufnr))
    end)

    it('keeps no-hunk review file records in quickfix with an empty active loclist', function()
      mock_repo_root(function(path)
        assert.are.equal('/tmp/repo/.', path)
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        if cmd[4] == 'rev-parse' then
          return { 'commit' }
        end
        if cmd[4] == 'merge-base' then
          return { 'merge-base-commit' }
        end
        if cmd[4] ~= 'diff' then
          return {}
        end
        return {
          'diff --git a/lua/mode.lua b/lua/mode.lua',
          'old mode 100644',
          'new mode 100755',
          'diff --git a/lua/changed.lua b/lua/changed.lua',
          '--- a/lua/changed.lua',
          '+++ b/lua/changed.lua',
          '@@ -1 +1 @@',
          '-old',
          '+new',
        }
      end)
      mock_runtime_attach(function() end)

      local bufnr = commands.greview({
        base = 'origin/main',
        target = 'refs/forge/pr/42',
        mode = 'merge-base',
        repo = '/tmp/repo',
      })
      table.insert(test_buffers, bufnr)

      local qf = quickfix_items()
      assert.are.equal(2, #qf)
      assert.are.equal(bufnr, qf[1].bufnr)
      assert.are.equal(1, qf[1].lnum)
      assert.is_true(qf[1].text:find('lua/mode.lua', 1, true) ~= nil)
      assert.are.equal(bufnr, qf[2].bufnr)
      assert.are.equal(4, qf[2].lnum)
      assert.is_true(qf[2].text:find('lua/changed.lua', 1, true) ~= nil)

      assert.are.equal(0, #loclist_items())

      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      vim.api.nvim_exec_autocmds('CursorMoved', { buffer = bufnr })

      local loc = loclist_items()
      assert.are.equal(1, #loc)
      assert.are.equal(7, loc[1].lnum)
      assert.is_true(loc[1].text:find('lua/changed.lua', 1, true) ~= nil)
    end)
  end)

  describe('review_file_at_line', function()
    local review_test_buffers = {}

    after_each(function()
      for _, bufnr in ipairs(review_test_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
      review_test_buffers = {}
    end)

    it('returns filename at cursor line', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(review_test_buffers, bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'diff --git a/foo.lua b/foo.lua',
        '--- a/foo.lua',
        '+++ b/foo.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local x = 1',
        ' return M',
      })

      assert.are.equal('foo.lua', commands.review_file_at_line(bufnr, 6))
    end)

    it('returns correct file in multi-file diff', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(review_test_buffers, bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'diff --git a/foo.lua b/foo.lua',
        '@@ -1 +1 @@',
        '-old',
        '+new',
        'diff --git a/bar.lua b/bar.lua',
        '@@ -1 +1 @@',
        '-old',
        '+new',
      })

      assert.are.equal('foo.lua', commands.review_file_at_line(bufnr, 3))
      assert.are.equal('bar.lua', commands.review_file_at_line(bufnr, 7))
    end)

    it('returns nil before any diff header', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(review_test_buffers, bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'some preamble text',
        'diff --git a/foo.lua b/foo.lua',
      })

      assert.is_nil(commands.review_file_at_line(bufnr, 1))
    end)

    it('returns nil on empty buffer', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(review_test_buffers, bufnr)

      assert.is_nil(commands.review_file_at_line(bufnr, 1))
    end)
  end)

  describe('find_hunk_line', function()
    it('finds matching @@ header and returns target line', function()
      local diff_lines = {
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      }
      local hunk_position = {
        hunk_header = '@@ -1,3 +1,4 @@',
        offset = 2,
      }
      local target_line = commands.find_hunk_line(diff_lines, hunk_position)
      assert.equals(6, target_line)
    end)

    it('returns nil when hunk header not found', function()
      local diff_lines = {
        'diff --git a/file.lua b/file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
      }
      local hunk_position = {
        hunk_header = '@@ -99,3 +99,4 @@',
        offset = 1,
      }
      local target_line = commands.find_hunk_line(diff_lines, hunk_position)
      assert.is_nil(target_line)
    end)

    it('handles multiple hunks and finds correct one', function()
      local diff_lines = {
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local x = 1',
        ' ',
        '@@ -10,3 +11,4 @@',
        ' function M.foo()',
        '+  print("hello")',
        ' end',
      }
      local hunk_position = {
        hunk_header = '@@ -10,3 +11,4 @@',
        offset = 2,
      }
      local target_line = commands.find_hunk_line(diff_lines, hunk_position)
      assert.equals(10, target_line)
    end)
  end)
end)
