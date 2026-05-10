local helpers = require('spec.helpers')

local commands = require('diffs.commands')
local diffspec = require('diffs.spec')
local git = require('diffs.git')
local rails = require('diffs.rails')
local runtime = require('diffs.runtime')

local saved_git = {}
local saved_notify
local saved_systemlist
local test_buffers = {}

local function mock_git(overrides)
  overrides = overrides or {}
  saved_git.get_file_content = git.get_file_content
  saved_git.get_index_content = git.get_index_content
  saved_git.get_working_content = git.get_working_content

  git.get_file_content = overrides.get_file_content
    or function()
      return { 'local M = {}', 'return M' }
    end
  git.get_index_content = overrides.get_index_content
    or function()
      return { 'local M = {}', 'return M' }
    end
  git.get_working_content = overrides.get_working_content
    or function()
      return { 'local M = {}', 'local x = 1', 'return M' }
    end
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

local function mock_notify(fn)
  saved_notify = vim.notify
  vim.notify = fn
end

local function restore_mocks()
  for k, v in pairs(saved_git) do
    git[k] = v
  end
  saved_git = {}
  if saved_notify then
    vim.notify = saved_notify
    saved_notify = nil
  end
  if saved_systemlist then
    vim.fn.systemlist = saved_systemlist
    saved_systemlist = nil
  end
end

---@param name string
---@param vars? table<string, any>
---@return integer
local function create_diffs_buffer(name, vars)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    vim.api.nvim_buf_delete(existing, { force = true })
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vars = vars or {}
  for k, v in pairs(vars) do
    vim.api.nvim_buf_set_var(bufnr, k, v)
  end
  table.insert(test_buffers, bufnr)
  return bufnr
end

local function cleanup_buffers()
  for _, bufnr in ipairs(test_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  test_buffers = {}
end

local function buffer_lines(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return rails.strip_lines(lines, rails.width_for_buffer(bufnr))
end

local function review_diff_lines()
  return {
    'diff --git a/file.lua b/file.lua',
    '--- a/file.lua',
    '+++ b/file.lua',
    '@@ -1 +1 @@',
    '-old',
    '+new',
  }
end

local function has_buf_var(bufnr, name)
  local ok = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  return ok
end

describe('read_buffer', function()
  after_each(function()
    restore_mocks()
    cleanup_buffers()
  end)

  describe('early returns', function()
    it('does nothing on non-diffs:// buffer', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, bufnr)
      assert.has_no.errors(function()
        commands.read_buffer(bufnr)
      end)
      assert.are.same({ '' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it('does nothing on malformed url without colon separator', function()
      local notification
      mock_notify(function(message, level)
        notification = { message = message, level = level }
      end)
      local bufnr = create_diffs_buffer('diffs://nocolonseparator')
      vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', '/tmp')
      local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.has_no.errors(function()
        commands.read_buffer(bufnr)
      end)
      assert.are.same(lines_before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(notification.message:find('malformed diffs:// buffer', 1, true) ~= nil)
    end)

    it('does nothing when diffs_repo_root is missing', function()
      local notification
      mock_notify(function(message, level)
        notification = { message = message, level = level }
      end)
      local bufnr = create_diffs_buffer('diffs://staged:missing_root.lua')
      assert.has_no.errors(function()
        commands.read_buffer(bufnr)
      end)
      assert.are.same({ '' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(notification.message:find('without diffs_repo_root', 1, true) ~= nil)
    end)
  end)

  describe('buffer options', function()
    it('sets buftype, bufhidden, swapfile, modifiable, filetype', function()
      mock_git()
      local bufnr = create_diffs_buffer('diffs://staged:options_test.lua', {
        diffs_repo_root = '/tmp',
      })

      commands.read_buffer(bufnr)

      assert.are.equal('nowrite', vim.api.nvim_get_option_value('buftype', { buf = bufnr }))
      assert.are.equal('delete', vim.api.nvim_get_option_value('bufhidden', { buf = bufnr }))
      assert.is_false(vim.api.nvim_get_option_value('swapfile', { buf = bufnr }))
      assert.is_false(vim.api.nvim_get_option_value('modifiable', { buf = bufnr }))
      assert.are.equal('diff', vim.api.nvim_get_option_value('filetype', { buf = bufnr }))
    end)
  end)

  describe('dispatch', function()
    it('calls get_file_content + get_index_content for staged label', function()
      local called_get_file = false
      local called_get_index = false
      mock_git({
        get_file_content = function()
          called_get_file = true
          return { 'old' }
        end,
        get_index_content = function()
          called_get_index = true
          return { 'new' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://staged:dispatch_staged.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.is_true(called_get_file)
      assert.is_true(called_get_index)
    end)

    it('calls get_index_content + get_working_content for unstaged label', function()
      local called_get_index = false
      local called_get_working = false
      mock_git({
        get_index_content = function()
          called_get_index = true
          return { 'index' }
        end,
        get_working_content = function()
          called_get_working = true
          return { 'working' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://unstaged:dispatch_unstaged.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.is_true(called_get_index)
      assert.is_true(called_get_working)
    end)

    it('calls only get_working_content for untracked label', function()
      local called_get_file = false
      local called_get_working = false
      mock_git({
        get_file_content = function()
          called_get_file = true
          return {}
        end,
        get_working_content = function()
          called_get_working = true
          return { 'new file' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://untracked:dispatch_untracked.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.is_false(called_get_file)
      assert.is_true(called_get_working)
    end)

    it('calls get_file_content + get_working_content for revision label', function()
      local captured_rev
      local called_get_working = false
      mock_git({
        get_file_content = function(rev)
          captured_rev = rev
          return { 'old' }
        end,
        get_working_content = function()
          called_get_working = true
          return { 'new' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://HEAD~3:dispatch_rev.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.are.equal('HEAD~3', captured_rev)
      assert.is_true(called_get_working)
    end)

    it('uses diffs_spec metadata without parsing the display name', function()
      local calls = {}
      mock_git({
        get_file_content = function(rev, filepath)
          table.insert(calls, { 'file', rev, filepath })
          return { 'tree' }
        end,
        get_index_content = function(filepath)
          table.insert(calls, { 'index', filepath })
          return { 'index' }
        end,
        get_working_content = function(filepath)
          table.insert(calls, { 'worktree', filepath })
          return { 'worktree' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://metadata-only', {
        diffs_repo_root = '/tmp',
        diffs_spec = diffspec.index_to_worktree('meta_unstaged.lua'),
      })
      commands.read_buffer(bufnr)

      assert.are.same({
        { 'index', '/tmp/meta_unstaged.lua' },
        { 'worktree', '/tmp/meta_unstaged.lua' },
      }, calls)
      local diff_hunks = vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('meta_unstaged.lua', diff_hunks[1].file)
      assert.is_true(diff_hunks[1].can_put)
      assert.is_false(diff_hunks[1].can_obtain)
      assert.is_true(diff_hunks[1].actionable)
      assert.are.equal('worktree', diff_hunks[1].mutation_target)
      assert.is_true(helpers.has_keymap(bufnr, ']c'))
      assert.is_true(helpers.has_keymap(bufnr, '[c'))
      assert.is_true(helpers.has_keymap(bufnr, '<CR>'))
      assert.is_false(helpers.has_keymap(bufnr, 'o'))
      assert.is_false(helpers.has_keymap(bufnr, 'do'))
      assert.is_true(helpers.has_keymap(bufnr, 'dp'))
    end)

    it('uses diffs_source metadata without parsing the display name', function()
      local calls = {}
      mock_git({
        get_file_content = function(rev, filepath)
          table.insert(calls, { 'file', rev, filepath })
          return { 'tree' }
        end,
        get_index_content = function(filepath)
          table.insert(calls, { 'index', filepath })
          return { 'index' }
        end,
        get_working_content = function(filepath)
          table.insert(calls, { 'worktree', filepath })
          return { 'worktree' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://metadata-only', {
        diffs_repo_root = '/wrong',
        diffs_source = {
          version = 1,
          kind = 'file',
          repo_root = '/tmp',
          spec = diffspec.index_to_worktree('source_meta.lua'),
        },
      })
      commands.read_buffer(bufnr)

      assert.are.same({
        { 'index', '/tmp/source_meta.lua' },
        { 'worktree', '/tmp/source_meta.lua' },
      }, calls)
      local diff_hunks = vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('source_meta.lua', diff_hunks[1].file)
      assert.is_true(diff_hunks[1].can_put)
      assert.is_false(diff_hunks[1].can_obtain)
      assert.is_true(diff_hunks[1].actionable)
    end)

    it('rejects standalone split endpoint reloads without adding pair actions', function()
      local called_index = false
      local notification
      mock_notify(function(message, level)
        notification = { message = message, level = level }
      end)
      mock_git({
        get_index_content = function()
          called_index = true
          return { 'local M = {}', 'return M' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://split:left:index:lua/foo.lua', {
        diffs_source = {
          version = 1,
          kind = 'split_endpoint',
          repo_root = '/tmp/repo',
          spec = diffspec.index_to_worktree('lua/foo.lua'),
          side = 'left',
          path = 'lua/foo.lua',
          filetype = 'lua',
        },
      })

      commands.read_buffer(bufnr)

      assert.is_false(called_index)
      assert.are.same({ '' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_false(has_buf_var(bufnr, 'diffs_split_side'))
      assert.is_false(has_buf_var(bufnr, 'diffs_split_peer'))
      assert.is_false(has_buf_var(bufnr, 'diffs_split_hunks'))
      assert.is_false(helpers.has_keymap(bufnr, 'q'))
      assert.is_false(helpers.has_keymap(bufnr, '<CR>'))
      assert.is_false(helpers.has_keymap(bufnr, ']c'))
      assert.is_false(helpers.has_keymap(bufnr, '[c'))
      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(notification.message:find('without a valid peer', 1, true) ~= nil)
    end)

    it('reloads both split endpoints from paired source metadata', function()
      mock_git()

      local source = {
        version = 1,
        kind = 'split_endpoint',
        repo_root = '/tmp/repo',
        spec = diffspec.index_to_worktree('lua/foo.lua'),
        path = 'lua/foo.lua',
        filetype = 'lua',
      }
      local left_buf = create_diffs_buffer('diffs://split:left:index:lua/foo.lua', {
        diffs_source = vim.tbl_extend('force', source, { side = 'left' }),
      })
      local right_buf = create_diffs_buffer('diffs://split:right:worktree:lua/foo.lua', {
        diffs_source = vim.tbl_extend('force', source, { side = 'right' }),
      })
      vim.api.nvim_buf_set_var(left_buf, 'diffs_split_peer', right_buf)
      vim.api.nvim_buf_set_var(right_buf, 'diffs_split_peer', left_buf)
      vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, { 'stale left' })
      vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { 'stale right' })

      commands.read_buffer(left_buf)

      assert.are.same(
        { 'local M = {}', 'return M' },
        vim.api.nvim_buf_get_lines(left_buf, 0, -1, false)
      )
      assert.are.same(
        { 'local M = {}', 'local x = 1', 'return M' },
        vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)
      )
      assert.are.equal(right_buf, vim.api.nvim_buf_get_var(left_buf, 'diffs_split_peer'))
      assert.are.equal(left_buf, vim.api.nvim_buf_get_var(right_buf, 'diffs_split_peer'))
      assert.are.equal(1, #vim.api.nvim_buf_get_var(left_buf, 'diffs_split_hunks'))
      assert.are.equal(1, #vim.api.nvim_buf_get_var(right_buf, 'diffs_split_hunks'))
    end)

    it('does not partially reload paired split endpoints when the peer read fails', function()
      mock_notify(function() end)
      mock_git({
        get_index_content = function()
          return { 'new left' }
        end,
        get_working_content = function()
          return nil, 'read failed'
        end,
      })

      local source = {
        version = 1,
        kind = 'split_endpoint',
        repo_root = '/tmp/repo',
        spec = diffspec.index_to_worktree('lua/foo.lua'),
        path = 'lua/foo.lua',
        filetype = 'lua',
      }
      local left_buf = create_diffs_buffer('diffs://split:left:index:lua/foo.lua', {
        diffs_source = vim.tbl_extend('force', source, { side = 'left' }),
      })
      local right_buf = create_diffs_buffer('diffs://split:right:worktree:lua/foo.lua', {
        diffs_source = vim.tbl_extend('force', source, { side = 'right' }),
      })
      vim.api.nvim_buf_set_var(left_buf, 'diffs_split_peer', right_buf)
      vim.api.nvim_buf_set_var(right_buf, 'diffs_split_peer', left_buf)
      vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, { 'stale left' })
      vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { 'stale right' })

      commands.read_buffer(left_buf)

      assert.are.same({ 'stale left' }, vim.api.nvim_buf_get_lines(left_buf, 0, -1, false))
      assert.are.same({ 'stale right' }, vim.api.nvim_buf_get_lines(right_buf, 0, -1, false))
    end)

    it('reloads untracked DiffSpec buffers with empty index content and hunk metadata', function()
      mock_git({
        get_index_content = function(filepath)
          assert.are.equal('/tmp/new.lua', filepath)
          return nil, 'file not in index'
        end,
        get_working_content = function(filepath)
          assert.are.equal('/tmp/new.lua', filepath)
          return { 'local M = {}', 'return M' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://untracked:new.lua', {
        diffs_repo_root = '/tmp',
        diffs_spec = diffspec.index_to_worktree('new.lua'),
      })
      commands.read_buffer(bufnr)

      local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      assert.is_true(text:find('new file mode 100644', 1, true) ~= nil)
      assert.is_true(text:find('--- /dev/null', 1, true) ~= nil)
      local diff_hunks = vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('new.lua', diff_hunks[1].file)
      assert.is_true(diff_hunks[1].actionable)
    end)

    it(
      'reloads staged deletion DiffSpec buffers with empty index content and hunk metadata',
      function()
        mock_git({
          get_file_content = function(rev, filepath)
            assert.are.equal('HEAD', rev)
            assert.are.equal('/tmp/deleted.lua', filepath)
            return { 'local M = {}', 'return M' }
          end,
          get_index_content = function(filepath)
            assert.are.equal('/tmp/deleted.lua', filepath)
            return nil, 'file not in index'
          end,
        })

        local bufnr = create_diffs_buffer('diffs://staged:deleted.lua', {
          diffs_repo_root = '/tmp',
          diffs_spec = diffspec.head_to_index('deleted.lua'),
        })
        commands.read_buffer(bufnr)

        local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
        assert.is_true(text:find('deleted file mode 100644', 1, true) ~= nil)
        assert.is_true(text:find('+++ /dev/null', 1, true) ~= nil)
        local diff_hunks = vim.api.nvim_buf_get_var(bufnr, 'diffs_hunks')
        assert.are.equal(1, #diff_hunks)
        assert.are.equal('deleted.lua', diff_hunks[1].file)
        assert.are.equal('index', diff_hunks[1].mutation_target)
      end
    )

    it('prefers diffs_spec metadata for HEAD to index reloads', function()
      local calls = {}
      mock_git({
        get_file_content = function(rev, filepath)
          table.insert(calls, { 'file', rev, filepath })
          return { 'head' }
        end,
        get_index_content = function(filepath)
          table.insert(calls, { 'index', filepath })
          return { 'index' }
        end,
        get_working_content = function(filepath)
          table.insert(calls, { 'worktree', filepath })
          return { 'worktree' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://unstaged:meta_staged.lua', {
        diffs_repo_root = '/tmp',
        diffs_spec = diffspec.head_to_index('meta_staged.lua'),
      })
      commands.read_buffer(bufnr)

      assert.are.same({
        { 'file', 'HEAD', '/tmp/meta_staged.lua' },
        { 'index', '/tmp/meta_staged.lua' },
      }, calls)
    end)

    it('prefers diffs_spec metadata for revision to worktree reloads', function()
      local calls = {}
      mock_git({
        get_file_content = function(rev, filepath)
          table.insert(calls, { 'file', rev, filepath })
          return { 'old' }
        end,
        get_index_content = function(filepath)
          table.insert(calls, { 'index', filepath })
          return { 'index' }
        end,
        get_working_content = function(filepath)
          table.insert(calls, { 'worktree', filepath })
          return { 'worktree' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://unstaged:meta_rev.lua', {
        diffs_repo_root = '/tmp',
        diffs_spec = diffspec.rev_to_worktree('HEAD~3', 'meta_rev.lua'),
      })
      commands.read_buffer(bufnr)

      assert.are.same({
        { 'file', 'HEAD~3', '/tmp/meta_rev.lua' },
        { 'worktree', '/tmp/meta_rev.lua' },
      }, calls)
    end)

    it('warns and leaves content unchanged for invalid diffs_source metadata', function()
      local notification
      mock_notify(function(message, level)
        notification = { message = message, level = level }
      end)

      local bufnr = create_diffs_buffer('diffs://unstaged:invalid_source.lua', {
        diffs_source = {
          version = 1,
          kind = 'file',
          repo_root = '/tmp',
        },
      })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'stale content' })

      commands.read_buffer(bufnr)

      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(notification.message:find('invalid diffs_source metadata', 1, true) ~= nil)
      assert.are.same({ 'stale content' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it('warns and leaves content unchanged for invalid diffs_spec metadata', function()
      local notification
      mock_notify(function(message, level)
        notification = { message = message, level = level }
      end)

      local bufnr = create_diffs_buffer('diffs://unstaged:invalid_meta.lua', {
        diffs_repo_root = '/tmp',
        diffs_spec = {
          left = { kind = 'bogus' },
          right = { kind = 'worktree' },
          scope = { kind = 'file', path = 'invalid_meta.lua' },
          mode = 'unified',
        },
      })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'stale content' })

      commands.read_buffer(bufnr)

      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(notification.message:find('invalid diffs_spec metadata', 1, true) ~= nil)
      assert.are.same({ 'stale content' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it('falls back from index to HEAD for unstaged when index returns nil', function()
      local call_order = {}
      mock_git({
        get_index_content = function()
          table.insert(call_order, 'index')
          return nil
        end,
        get_file_content = function()
          table.insert(call_order, 'head')
          return { 'head content' }
        end,
        get_working_content = function()
          return { 'working content' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://unstaged:dispatch_fallback.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.are.same({ 'index', 'head' }, call_order)
    end)

    it('runs git diff for section diffs with path=all', function()
      local captured_cmd
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

      local bufnr = create_diffs_buffer('diffs://unstaged:all', {
        diffs_repo_root = '/home/test/repo',
      })
      commands.read_buffer(bufnr)

      assert.is_not_nil(captured_cmd)
      assert.are.equal('git', captured_cmd[1])
      assert.are.equal('/home/test/repo', captured_cmd[3])
      assert.are.equal('diff', captured_cmd[4])

      local lines = buffer_lines(bufnr)
      assert.are.equal('diff --git a/file.lua b/file.lua', lines[1])
    end)

    it('passes --cached for staged section diffs', function()
      local captured_cmd
      mock_systemlist(function(cmd)
        captured_cmd = cmd
        return { 'diff --git a/f.lua b/f.lua', '@@ -1 +1 @@', '-a', '+b' }
      end)

      local bufnr = create_diffs_buffer('diffs://staged:all', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.is_truthy(vim.tbl_contains(captured_cmd, '--cached'))
    end)

    it('runs git diff with base ref for review label', function()
      local captured_cmd
      mock_systemlist(function(cmd)
        if cmd[4] == 'rev-parse' then
          return { 'commit' }
        end
        if cmd[4] ~= 'diff' then
          return {}
        end
        captured_cmd = cmd
        return review_diff_lines()
      end)

      local bufnr = create_diffs_buffer('diffs://review:origin/main', {
        diffs_repo_root = '/home/test/repo',
      })
      commands.read_buffer(bufnr)

      assert.is_not_nil(captured_cmd)
      assert.are.equal('git', captured_cmd[1])
      assert.are.equal('/home/test/repo', captured_cmd[3])
      assert.are.equal('diff', captured_cmd[4])
      assert.are.equal('origin/main', captured_cmd[#captured_cmd])

      local lines = buffer_lines(bufnr)
      assert.are.equal('diff --git a/file.lua b/file.lua', lines[1])
    end)

    it('runs merge-base review reload from stored review vars', function()
      local captured_cmd
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
        return review_diff_lines()
      end)

      local bufnr = create_diffs_buffer('diffs://review:origin/main...refs/forge/pr/42', {
        diffs_repo_root = '/home/test/repo',
        diffs_review_base = 'origin/main',
        diffs_review_target = 'refs/forge/pr/42',
        diffs_review_mode = 'merge-base',
      })
      commands.read_buffer(bufnr)

      assert.are.same({
        'git',
        '-C',
        '/home/test/repo',
        'diff',
        '--no-ext-diff',
        '--no-color',
        '--merge-base',
        'origin/main',
        'refs/forge/pr/42',
      }, captured_cmd)
    end)

    it('parses direct review specs from the buffer name when vars are absent', function()
      local captured_cmd
      mock_systemlist(function(cmd)
        if cmd[4] == 'rev-parse' then
          return { 'commit' }
        end
        if cmd[4] ~= 'diff' then
          return {}
        end
        captured_cmd = cmd
        return review_diff_lines()
      end)

      local bufnr = create_diffs_buffer('diffs://review:origin/main..feature/topic', {
        diffs_repo_root = '/home/test/repo',
      })
      commands.read_buffer(bufnr)

      assert.are.same({
        'git',
        '-C',
        '/home/test/repo',
        'diff',
        '--no-ext-diff',
        '--no-color',
        'origin/main',
        'feature/topic',
      }, captured_cmd)
    end)

    it('reports missing review refs on reload without replacing buffer lines', function()
      local called_diff = false
      local notification
      mock_notify(function(message, level)
        notification = { message = message, level = level }
      end)
      mock_systemlist(function(cmd)
        if cmd[4] == 'diff' then
          called_diff = true
        elseif cmd[4] == 'rev-parse' then
          return {}, 1
        end
        return {}
      end)

      local bufnr = create_diffs_buffer('diffs://review:missing/ref', {
        diffs_repo_root = '/home/test/repo',
      })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'stale review' })

      commands.read_buffer(bufnr)

      assert.is_false(called_diff)
      assert.are.same({ 'stale review' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(
        notification.message:find(
          'Greview base ref not found: missing/ref (spec: missing/ref)',
          1,
          true
        ) ~= nil
      )
    end)

    it('reports missing review refs from source metadata without replacing buffer lines', function()
      local called_diff = false
      local notification
      local validation_repo
      mock_notify(function(message, level)
        notification = { message = message, level = level }
      end)
      mock_systemlist(function(cmd)
        if cmd[4] == 'diff' then
          called_diff = true
        elseif cmd[4] == 'rev-parse' then
          validation_repo = cmd[3]
          return {}, 1
        end
        return {}
      end)

      local bufnr = create_diffs_buffer('diffs://review:missing/ref', {
        diffs_repo_root = '/wrong/repo',
        diffs_source = {
          version = 1,
          kind = 'review',
          repo_root = '/home/test/repo',
          review = {
            base = 'missing/ref',
          },
        },
      })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'stale review' })

      commands.read_buffer(bufnr)

      assert.is_false(called_diff)
      assert.are.equal('/home/test/repo', validation_repo)
      assert.are.same({ 'stale review' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(
        notification.message:find(
          'Greview base ref not found: missing/ref (spec: missing/ref)',
          1,
          true
        ) ~= nil
      )
    end)
  end)

  describe('content', function()
    it('generates valid unified diff header with correct paths', function()
      mock_git({
        get_file_content = function()
          return { 'old' }
        end,
        get_working_content = function()
          return { 'new' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://HEAD:lua/diffs/init.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      local lines = buffer_lines(bufnr)
      assert.are.equal('diff --git a/lua/diffs/init.lua b/lua/diffs/init.lua', lines[1])
      assert.are.equal('--- a/lua/diffs/init.lua', lines[2])
      assert.are.equal('+++ b/lua/diffs/init.lua', lines[3])
    end)

    it('uses old_filepath for diff header in renames', function()
      mock_git({
        get_file_content = function(_, path)
          assert.are.equal('/tmp/old_name.lua', path)
          return { 'old content' }
        end,
        get_index_content = function()
          return { 'new content' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://staged:new_name.lua', {
        diffs_repo_root = '/tmp',
        diffs_old_filepath = 'old_name.lua',
      })
      commands.read_buffer(bufnr)

      local lines = buffer_lines(bufnr)
      assert.are.equal('diff --git a/old_name.lua b/new_name.lua', lines[1])
      assert.are.equal('--- a/old_name.lua', lines[2])
      assert.are.equal('+++ b/new_name.lua', lines[3])
    end)

    it('produces empty buffer when old and new are identical', function()
      mock_git({
        get_file_content = function()
          return { 'identical' }
        end,
        get_working_content = function()
          return { 'identical' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://HEAD:nodiff.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.same({ '' }, lines)
    end)

    it('replaces existing buffer content on reload', function()
      mock_git({
        get_file_content = function()
          return { 'old' }
        end,
        get_working_content = function()
          return { 'new' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://HEAD:replace_test.lua', {
        diffs_repo_root = '/tmp',
      })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'stale', 'content', 'from', 'before' })

      commands.read_buffer(bufnr)

      local lines = buffer_lines(bufnr)
      assert.are.equal('diff --git a/replace_test.lua b/replace_test.lua', lines[1])
      for _, line in ipairs(lines) do
        assert.is_not_equal('stale', line)
      end
    end)
  end)

  describe('attach integration', function()
    it('calls attach on the buffer', function()
      mock_git()

      local attach_called_with
      local original_attach = runtime.attach
      runtime.attach = function(bufnr)
        attach_called_with = bufnr
      end

      local bufnr = create_diffs_buffer('diffs://staged:attach_test.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.are.equal(bufnr, attach_called_with)

      runtime.attach = original_attach
    end)
  end)
end)
