local helpers = require('spec.helpers')

local commands = require('diffs.commands')
local diffspec = require('diffs.spec')
local git = require('diffs.git')
local rails = require('diffs.rails')
local runtime = require('diffs.runtime')

local saved_git = {}
local saved_runtime_attach
local saved_runtime_get_conflict_config
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
    local result = fn(cmd)
    saved_systemlist({ 'true' })
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
    return rails.strip_lines(lines, rail_width)
  end
  return lines
end

local function buffer_text(bufnr)
  return table.concat(buffer_lines(bufnr), '\n')
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
  end)

  describe('setup', function()
    it('registers Gdiff, Gvdiff, and Ghdiff commands', function()
      commands.setup()
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Gdiff)
      assert.is_not_nil(cmds.Gvdiff)
      assert.is_not_nil(cmds.Ghdiff)
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
    local function create_split_source()
      local source_buf = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, source_buf)
      vim.api.nvim_buf_set_name(source_buf, '/tmp/repo/lua/foo.lua')
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
        'local M = {}',
        'local x = 1',
        'return M',
      })
      vim.api.nvim_set_option_value('filetype', 'lua', { buf = source_buf })
      vim.api.nvim_set_current_buf(source_buf)

      mock_git_method('get_relative_path', function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return 'lua/foo.lua'
      end)
      mock_git_method('get_index_content', function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
        return { 'local M = {}', 'return M' }
      end)
      mock_repo_root(function(filepath)
        assert.are.equal('/tmp/repo/lua/foo.lua', filepath)
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
      assert.are.equal(6, vim.api.nvim_buf_get_var(diff_buf, 'diffs_rail_width'))
      assert.are.equal('    | diff --git a/lua/foo.lua b/lua/foo.lua', display_lines[1])
      assert.is_true(table.concat(display_lines, '\n'):find('  2 | +local x = 1', 1, true) ~= nil)
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
      assert.are.equal('manual', vim.api.nvim_get_option_value('foldmethod', { win = left_win }))
      assert.are.equal('manual', vim.api.nvim_get_option_value('foldmethod', { win = right_win }))
      assert.is_false(vim.api.nvim_get_option_value('foldenable', { win = left_win }))
      assert.is_false(vim.api.nvim_get_option_value('foldenable', { win = right_win }))
      assert.are.equal('0', vim.api.nvim_get_option_value('foldcolumn', { win = left_win }))
      assert.are.equal('0', vim.api.nvim_get_option_value('foldcolumn', { win = right_win }))
      assert.is_true(helpers.has_keymap(left_buf, 'q'))
      assert.is_true(helpers.has_keymap(right_buf, 'q'))
      assert.is_true(helpers.has_keymap(left_buf, '<CR>'))
      assert.is_true(helpers.has_keymap(right_buf, '<CR>'))
      assert.is_false(helpers.has_keymap(right_buf, 'dp'))
      assert.is_false(helpers.has_keymap(right_buf, 'do'))
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

      local function assert_unmerged_view(bufnr)
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
      end

      assert_unmerged_view(diff_buf)

      vim.api.nvim_set_option_value('modifiable', true, { buf = diff_buf })
      vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, { 'stale unmerged content' })
      vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })

      commands.read_buffer(diff_buf)

      assert_unmerged_view(diff_buf)
      helpers.delete_buffer(diff_buf)

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

    it('normalizes default base inside the resolved repo', function()
      local captured_cmd
      mock_repo_root(function(path)
        assert.are.equal('/tmp/repo/.', path)
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
        captured_cmd = cmd
        return { 'refs/remotes/origin/main' }
      end)

      local review = commands._test.normalize_greview({ repo = '/tmp/repo' })

      assert.are.equal('/tmp/repo', review.repo_root)
      assert.are.equal('origin/main', review.base)
      assert.are.equal('origin/main', review.display)
      assert.are.same(
        { 'git', '-C', '/tmp/repo', 'symbolic-ref', 'refs/remotes/origin/HEAD' },
        captured_cmd
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
  end)

  describe('greview', function()
    it('opens a review buffer for an explicit merge-base target', function()
      local captured_cmd
      mock_repo_root(function(path)
        assert.are.equal('/tmp/repo/.', path)
        return '/tmp/repo'
      end)
      mock_systemlist(function(cmd)
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
