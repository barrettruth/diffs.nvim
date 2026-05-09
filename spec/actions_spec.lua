require('spec.helpers')

local actions = require('diffs.actions')
local commands = require('diffs.commands')
local diffspec = require('diffs.spec')
local git = require('diffs.git')
local hunk_model = require('diffs.hunks')
local render = require('diffs.render')

local test_buffers = {}
local test_repos = {}
local saved_notify
local saved_git_apply_patch
local buffer_counter = 0

local function git_cmd(repo_root, args)
  local cmd = { 'git', '-C', repo_root }
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end
  local output = vim.fn.systemlist(cmd)
  assert.are.equal(0, vim.v.shell_error, table.concat(output, '\n'))
  return output
end

local function git_text(repo_root, args)
  return table.concat(git_cmd(repo_root, args), '\n')
end

local function write_repo_file(repo_root, lines)
  vim.fn.writefile(lines, repo_root .. '/file.txt')
end

local function file_lines(overrides)
  local lines = {}
  for i = 1, 30 do
    lines[i] = 'line ' .. i
  end
  for lnum, line in pairs(overrides or {}) do
    lines[lnum] = line
  end
  return lines
end

local function file_lines_with_insertions(after, inserted)
  local lines = file_lines()
  for offset, line in ipairs(inserted) do
    table.insert(lines, after + offset, line)
  end
  return lines
end

local function file_lines_without(start, count)
  local lines = file_lines()
  for _ = 1, count do
    table.remove(lines, start)
  end
  return lines
end

local function create_repo()
  local repo_root = vim.fn.tempname()
  vim.fn.mkdir(repo_root, 'p')
  test_repos[#test_repos + 1] = repo_root

  vim.fn.systemlist({ 'git', 'init', '-q', repo_root })
  assert.are.equal(0, vim.v.shell_error)
  git_cmd(repo_root, { 'config', 'user.email', 'test@example.com' })
  git_cmd(repo_root, { 'config', 'user.name', 'Test' })
  write_repo_file(repo_root, file_lines())
  git_cmd(repo_root, { 'add', 'file.txt' })
  git_cmd(repo_root, { 'commit', '-qm', 'initial' })

  return repo_root
end

local function create_diff_buffer(repo_root, diff_spec)
  local diff_lines = assert(render.file(diff_spec, repo_root))
  buffer_counter = buffer_counter + 1
  local bufnr = vim.api.nvim_create_buf(false, true)
  test_buffers[#test_buffers + 1] = bufnr
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, diff_lines)
  vim.api.nvim_buf_set_name(bufnr, 'diffs://actions-' .. buffer_counter .. ':file.txt')
  vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', repo_root)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_spec', diff_spec)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_hunks', hunk_model.parse(diff_lines, diff_spec))
  vim.api.nvim_set_current_buf(bufnr)
  commands.setup_diff_buf(bufnr)
  return bufnr
end

local function keymap_callback(bufnr, lhs, mode)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode or 'n')) do
    if keymap.lhs == lhs then
      return keymap.callback
    end
  end
  return nil
end

local function find_hunk_line(bufnr, kind, text)
  for _, hunk in ipairs(vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')) do
    for _, line in ipairs(hunk.lines) do
      if line.kind == kind and line.text == text then
        return line, hunk
      end
    end
  end
  error('could not find hunk line ' .. kind .. ' ' .. text)
end

local function find_hunks(bufnr)
  return vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')
end

local function set_visual_range(bufnr, range_start, range_finish)
  vim.api.nvim_buf_set_mark(bufnr, '<', range_start, 0, {})
  vim.api.nvim_buf_set_mark(bufnr, '>', range_finish, 0, {})
end

local function move_to_hunk(bufnr, index)
  local hunks = vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')
  vim.api.nvim_win_set_cursor(0, { hunks[index].buffer_range.start, 0 })
end

local function buffer_text(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
end

local function capture_notifications()
  local notifications = {}
  saved_notify = vim.notify
  vim.notify = function(message, level)
    notifications[#notifications + 1] = { message = message, level = level }
  end
  return notifications
end

local function cleanup()
  if saved_notify then
    vim.notify = saved_notify
    saved_notify = nil
  end
  if saved_git_apply_patch then
    git.apply_patch = saved_git_apply_patch
    saved_git_apply_patch = nil
  end
  for _, bufnr in ipairs(test_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  test_buffers = {}
  for _, repo_root in ipairs(test_repos) do
    vim.fn.delete(repo_root, 'rf')
  end
  test_repos = {}
end

describe('diffs.actions', function()
  after_each(cleanup)

  it('builds a one-hunk patch from stored file headers and hunk lines', function()
    local diff_lines = {
      'diff --git a/file.txt b/file.txt',
      '--- a/file.txt',
      '+++ b/file.txt',
      '@@ -1 +1 @@',
      '-one',
      '+two',
      '@@ -10 +10 @@',
      '-ten',
      '+eleven',
    }
    local hunks = hunk_model.parse(diff_lines, diffspec.index_to_worktree('file.txt'))

    local patch = assert(actions.patch_for_hunk(hunks[2]))

    assert.are.equal(
      table.concat({
        'diff --git a/file.txt b/file.txt',
        '--- a/file.txt',
        '+++ b/file.txt',
        '@@ -10 +10 @@',
        '-ten',
        '+eleven',
        '',
      }, '\n'),
      patch
    )
  end)

  it('builds a selected-add range patch for the side receiving the patch', function()
    local diff_lines = {
      'diff --git a/file.txt b/file.txt',
      '--- a/file.txt',
      '+++ b/file.txt',
      '@@ -1 +1,3 @@',
      ' line 1',
      '+insert alpha',
      '+insert beta',
    }
    local hunk = hunk_model.parse(diff_lines, diffspec.index_to_worktree('file.txt'))[1]

    local patch = assert(actions.patch_for_range(hunk, 7, 7, { target = 'left' }))
    local reverse_patch = assert(actions.patch_for_range(hunk, 7, 7, { target = 'right' }))

    assert.are.equal(
      table.concat({
        'diff --git a/file.txt b/file.txt',
        '--- a/file.txt',
        '+++ b/file.txt',
        '@@ -1 +1,3 @@',
        ' line 1',
        '+insert beta',
        '',
      }, '\n'),
      patch
    )
    assert.are.equal(
      table.concat({
        'diff --git a/file.txt b/file.txt',
        '--- a/file.txt',
        '+++ b/file.txt',
        '@@ -1 +1,3 @@',
        ' line 1',
        ' insert alpha',
        '+insert beta',
        '',
      }, '\n'),
      reverse_patch
    )
  end)

  it('builds a selected-delete range patch for the side receiving the patch', function()
    local diff_lines = {
      'diff --git a/file.txt b/file.txt',
      '--- a/file.txt',
      '+++ b/file.txt',
      '@@ -1,3 +1 @@',
      ' line 1',
      '-delete alpha',
      '-delete beta',
    }
    local hunk = hunk_model.parse(diff_lines, diffspec.index_to_worktree('file.txt'))[1]

    local patch = assert(actions.patch_for_range(hunk, 7, 7, { target = 'left' }))
    local reverse_patch = assert(actions.patch_for_range(hunk, 7, 7, { target = 'right' }))

    assert.are.equal(
      table.concat({
        'diff --git a/file.txt b/file.txt',
        '--- a/file.txt',
        '+++ b/file.txt',
        '@@ -1,3 +1 @@',
        ' line 1',
        ' delete alpha',
        '-delete beta',
        '',
      }, '\n'),
      patch
    )
    assert.are.equal(
      table.concat({
        'diff --git a/file.txt b/file.txt',
        '--- a/file.txt',
        '+++ b/file.txt',
        '@@ -1,3 +1 @@',
        ' line 1',
        '-delete beta',
        '',
      }, '\n'),
      reverse_patch
    )
  end)

  it('rejects partial replacement-group ranges before building a patch', function()
    local diff_lines = {
      'diff --git a/file.txt b/file.txt',
      '--- a/file.txt',
      '+++ b/file.txt',
      '@@ -1,2 +1,2 @@',
      ' line 1',
      '-old',
      '+new',
    }
    local hunk = hunk_model.parse(diff_lines, diffspec.index_to_worktree('file.txt'))[1]

    local patch, err = actions.patch_for_range(hunk, 7, 7)

    assert.is_nil(patch)
    assert.are.equal('select the complete replacement group before applying it', err)
  end)

  it('stages only the current unstaged hunk and refreshes the buffer', function()
    local repo_root = create_repo()
    write_repo_file(
      repo_root,
      file_lines({
        [2] = 'line 2 changed',
        [22] = 'line 22 changed',
      })
    )

    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))
    move_to_hunk(bufnr, 1)

    assert.is_not_nil(keymap_callback(bufnr, 'dp'))
    keymap_callback(bufnr, 'dp')()

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    local worktree =
      git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' })

    assert.is_true(cached:find('+line 2 changed', 1, true) ~= nil)
    assert.is_nil(cached:find('+line 22 changed', 1, true))
    assert.is_nil(worktree:find('+line 2 changed', 1, true))
    assert.is_true(worktree:find('+line 22 changed', 1, true) ~= nil)
    assert.is_nil(buffer_text(bufnr):find('+line 2 changed', 1, true))
    assert.is_true(buffer_text(bufnr):find('+line 22 changed', 1, true) ~= nil)
  end)

  it('stages an untracked file hunk as a new file', function()
    local repo_root = create_repo()
    vim.fn.writefile({ 'new file line' }, repo_root .. '/new.txt')

    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('new.txt'))
    move_to_hunk(bufnr, 1)

    assert.is_true(actions.put_hunk(bufnr))

    local cached =
      git_text(repo_root, { 'diff', '--cached', '--no-ext-diff', '--no-color', '--', 'new.txt' })
    local worktree = git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '--', 'new.txt' })

    assert.is_true(cached:find('new file mode 100644', 1, true) ~= nil)
    assert.is_true(cached:find('--- /dev/null', 1, true) ~= nil)
    assert.is_true(cached:find('+new file line', 1, true) ~= nil)
    assert.are.equal('', worktree)
  end)

  it('stages only selected added lines from a visual range', function()
    local repo_root = create_repo()
    write_repo_file(
      repo_root,
      file_lines_with_insertions(2, {
        'insert alpha',
        'insert beta',
      })
    )

    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))
    local selected = find_hunk_line(bufnr, 'add', '+insert beta')

    assert.is_true(actions.put_range(bufnr, selected.lnum, selected.lnum))

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    local worktree =
      git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' })

    assert.is_true(cached:find('+insert beta', 1, true) ~= nil)
    assert.is_nil(cached:find('+insert alpha', 1, true))
    assert.is_true(worktree:find('+insert alpha', 1, true) ~= nil)
    assert.is_nil(worktree:find('+insert beta', 1, true))
  end)

  it('stages a visual selection through the buffer-local dp map and refreshes', function()
    local repo_root = create_repo()
    write_repo_file(
      repo_root,
      file_lines_with_insertions(2, {
        'insert alpha',
        'insert beta',
      })
    )

    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))
    local selected = find_hunk_line(bufnr, 'add', '+insert beta')
    local callback = assert(keymap_callback(bufnr, 'dp', 'x'))

    set_visual_range(bufnr, selected.lnum, selected.lnum)
    callback()

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )

    assert.is_true(cached:find('+insert beta', 1, true) ~= nil)
    assert.is_nil(cached:find('+insert alpha', 1, true))
    assert.is_nil(buffer_text(bufnr):find('+insert beta', 1, true))
    assert.is_true(buffer_text(bufnr):find('+insert alpha', 1, true) ~= nil)
  end)

  it('stages only selected deleted lines from a visual range', function()
    local repo_root = create_repo()
    write_repo_file(repo_root, file_lines_without(3, 2))

    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))
    local selected = find_hunk_line(bufnr, 'delete', '-line 4')

    assert.is_true(actions.put_range(bufnr, selected.lnum, selected.lnum))

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    local worktree =
      git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' })

    assert.is_true(cached:find('-line 4', 1, true) ~= nil)
    assert.is_nil(cached:find('-line 3', 1, true))
    assert.is_true(worktree:find('-line 3', 1, true) ~= nil)
    assert.is_nil(worktree:find('-line 4', 1, true))
  end)

  it('unstages only the current staged hunk and refreshes the buffer', function()
    local repo_root = create_repo()
    write_repo_file(repo_root, file_lines({ [2] = 'line 2 changed' }))
    git_cmd(repo_root, { 'add', 'file.txt' })
    write_repo_file(
      repo_root,
      file_lines({
        [2] = 'line 2 changed',
        [22] = 'line 22 changed',
      })
    )

    local bufnr = create_diff_buffer(repo_root, diffspec.head_to_index('file.txt'))
    move_to_hunk(bufnr, 1)

    assert.is_not_nil(keymap_callback(bufnr, 'do'))
    keymap_callback(bufnr, 'do')()

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    local worktree =
      git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' })

    assert.are.equal('', cached)
    assert.is_true(worktree:find('+line 2 changed', 1, true) ~= nil)
    assert.is_true(worktree:find('+line 22 changed', 1, true) ~= nil)
    assert.are.equal(0, #vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks'))
  end)

  it('unstages a staged added-file hunk back to an untracked file', function()
    local repo_root = create_repo()
    vim.fn.writefile({ 'new file line' }, repo_root .. '/new.txt')
    git_cmd(repo_root, { 'add', 'new.txt' })

    local bufnr = create_diff_buffer(repo_root, diffspec.head_to_index('new.txt'))
    move_to_hunk(bufnr, 1)

    assert.is_true(actions.obtain_hunk(bufnr))

    local cached =
      git_text(repo_root, { 'diff', '--cached', '--no-ext-diff', '--no-color', '--', 'new.txt' })
    vim.fn.systemlist({ 'git', '-C', repo_root, 'ls-files', '--error-unmatch', 'new.txt' })

    assert.are.equal('', cached)
    assert.is_not.equal(0, vim.v.shell_error)
  end)

  it('stages an unstaged deletion hunk', function()
    local repo_root = create_repo()
    vim.fn.delete(repo_root .. '/file.txt')

    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))
    move_to_hunk(bufnr, 1)

    assert.is_true(actions.put_hunk(bufnr))

    local cached =
      git_text(repo_root, { 'diff', '--cached', '--no-ext-diff', '--no-color', '--', 'file.txt' })
    local worktree =
      git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '--', 'file.txt' })

    assert.is_true(cached:find('deleted file mode 100644', 1, true) ~= nil)
    assert.is_true(cached:find('+++ /dev/null', 1, true) ~= nil)
    assert.is_true(cached:find('-line 1', 1, true) ~= nil)
    assert.are.equal('', worktree)
  end)

  it('unstages a staged deletion hunk back to an unstaged deletion', function()
    local repo_root = create_repo()
    vim.fn.delete(repo_root .. '/file.txt')
    git_cmd(repo_root, { 'add', '-u', 'file.txt' })

    local bufnr = create_diff_buffer(repo_root, diffspec.head_to_index('file.txt'))
    move_to_hunk(bufnr, 1)

    assert.is_true(actions.obtain_hunk(bufnr))

    local cached =
      git_text(repo_root, { 'diff', '--cached', '--no-ext-diff', '--no-color', '--', 'file.txt' })
    local worktree =
      git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '--', 'file.txt' })

    assert.are.equal('', cached)
    assert.is_true(worktree:find('deleted file mode 100644', 1, true) ~= nil)
    assert.is_true(worktree:find('+++ /dev/null', 1, true) ~= nil)
    assert.is_true(worktree:find('-line 1', 1, true) ~= nil)
  end)

  it('unstages only selected added lines from a visual range', function()
    local repo_root = create_repo()
    write_repo_file(
      repo_root,
      file_lines_with_insertions(2, {
        'insert alpha',
        'insert beta',
      })
    )
    git_cmd(repo_root, { 'add', 'file.txt' })

    local bufnr = create_diff_buffer(repo_root, diffspec.head_to_index('file.txt'))
    local selected = find_hunk_line(bufnr, 'add', '+insert beta')

    assert.is_true(actions.obtain_range(bufnr, selected.lnum, selected.lnum))

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    local worktree =
      git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' })

    assert.is_true(cached:find('+insert alpha', 1, true) ~= nil)
    assert.is_nil(cached:find('+insert beta', 1, true))
    assert.is_true(worktree:find('+insert beta', 1, true) ~= nil)
    assert.is_nil(worktree:find('+insert alpha', 1, true))
  end)

  it('unstages a visual selection through the buffer-local do map and refreshes', function()
    local repo_root = create_repo()
    write_repo_file(
      repo_root,
      file_lines_with_insertions(2, {
        'insert alpha',
        'insert beta',
      })
    )
    git_cmd(repo_root, { 'add', 'file.txt' })

    local bufnr = create_diff_buffer(repo_root, diffspec.head_to_index('file.txt'))
    local selected = find_hunk_line(bufnr, 'add', '+insert beta')
    local callback = assert(keymap_callback(bufnr, 'do', 'x'))

    set_visual_range(bufnr, selected.lnum, selected.lnum)
    callback()

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )

    assert.is_true(cached:find('+insert alpha', 1, true) ~= nil)
    assert.is_nil(cached:find('+insert beta', 1, true))
    assert.is_nil(buffer_text(bufnr):find('+insert beta', 1, true))
    assert.is_true(buffer_text(bufnr):find('+insert alpha', 1, true) ~= nil)
  end)

  it('unstages only selected deleted lines from a visual range', function()
    local repo_root = create_repo()
    write_repo_file(repo_root, file_lines_without(3, 2))
    git_cmd(repo_root, { 'add', 'file.txt' })

    local bufnr = create_diff_buffer(repo_root, diffspec.head_to_index('file.txt'))
    local selected = find_hunk_line(bufnr, 'delete', '-line 4')

    assert.is_true(actions.obtain_range(bufnr, selected.lnum, selected.lnum))

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    local worktree =
      git_text(repo_root, { 'diff', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' })

    assert.is_true(cached:find('-line 3', 1, true) ~= nil)
    assert.is_nil(cached:find('-line 4', 1, true))
    assert.is_true(worktree:find('-line 4', 1, true) ~= nil)
    assert.is_nil(worktree:find('-line 3', 1, true))
  end)

  it('rejects visual ranges that cross Gdiff hunks without touching the index', function()
    local notifications = capture_notifications()
    local repo_root = create_repo()
    write_repo_file(
      repo_root,
      file_lines({
        [2] = 'line 2 changed',
        [22] = 'line 22 changed',
      })
    )

    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))
    local hunks = find_hunks(bufnr)

    assert.is_false(
      actions.put_range(bufnr, hunks[1].buffer_range.finish, hunks[2].buffer_range.start)
    )

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    assert.are.equal('', cached)
    assert.is_true(
      notifications[#notifications].message:find(
        'visual selection must stay within one Gdiff hunk',
        1,
        true
      ) ~= nil
    )
  end)

  it('rejects partial replacement visual ranges without touching the index', function()
    local notifications = capture_notifications()
    local repo_root = create_repo()
    write_repo_file(repo_root, file_lines({ [2] = 'line 2 changed' }))

    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))
    local selected = find_hunk_line(bufnr, 'add', '+line 2 changed')

    assert.is_false(actions.put_range(bufnr, selected.lnum, selected.lnum))

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    assert.are.equal('', cached)
    assert.is_true(
      notifications[#notifications].message:find('complete replacement group', 1, true) ~= nil
    )
  end)

  it('leaves the index untouched when the apply check fails', function()
    local notifications = capture_notifications()
    local repo_root = create_repo()
    write_repo_file(repo_root, file_lines({ [2] = 'line 2 changed' }))
    local bufnr = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))

    write_repo_file(repo_root, file_lines({ [2] = 'line 2 other' }))
    git_cmd(repo_root, { 'add', 'file.txt' })
    write_repo_file(repo_root, file_lines({ [2] = 'line 2 changed' }))
    move_to_hunk(bufnr, 1)

    assert.is_false(actions.put_hunk(bufnr))

    local cached = git_text(
      repo_root,
      { 'diff', '--cached', '--no-ext-diff', '--no-color', '-U0', '--', 'file.txt' }
    )
    assert.is_true(cached:find('+line 2 other', 1, true) ~= nil)
    assert.is_nil(cached:find('+line 2 changed', 1, true))
    assert.is_true(
      notifications[#notifications].message:find('patch does not apply', 1, true) ~= nil
    )
  end)

  it('rejects read-only and unsupported hunk edges without running git apply', function()
    local notifications = capture_notifications()
    local calls = 0
    saved_git_apply_patch = git.apply_patch
    git.apply_patch = function()
      calls = calls + 1
      return true, {}
    end

    local repo_root = create_repo()
    write_repo_file(repo_root, file_lines({ [2] = 'line 2 changed' }))
    local bufnr = create_diff_buffer(repo_root, diffspec.rev_to_worktree('HEAD', 'file.txt'))
    move_to_hunk(bufnr, 1)

    assert.is_false(actions.put_hunk(bufnr))
    assert.is_false(actions.obtain_hunk(bufnr))
    assert.are.equal(0, calls)
    assert.is_true(notifications[1].message:find('read-only Gdiff hunk', 1, true) ~= nil)
    assert.is_true(notifications[2].message:find('read-only Gdiff hunk', 1, true) ~= nil)
  end)

  it('rejects destructive worktree restore and redundant index put operations', function()
    local notifications = capture_notifications()
    local repo_root = create_repo()
    write_repo_file(repo_root, file_lines({ [2] = 'line 2 changed' }))
    local unstaged_buf = create_diff_buffer(repo_root, diffspec.index_to_worktree('file.txt'))
    move_to_hunk(unstaged_buf, 1)

    assert.is_false(actions.obtain_hunk(unstaged_buf))

    write_repo_file(repo_root, file_lines({ [2] = 'line 2 changed' }))
    git_cmd(repo_root, { 'add', 'file.txt' })
    local staged_buf = create_diff_buffer(repo_root, diffspec.head_to_index('file.txt'))
    move_to_hunk(staged_buf, 1)

    assert.is_false(actions.put_hunk(staged_buf))
    assert.is_true(
      notifications[1].message:find('restoring worktree hunks is not supported', 1, true) ~= nil
    )
    assert.is_true(notifications[2].message:find('already in the index', 1, true) ~= nil)
  end)
end)
