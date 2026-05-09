local helpers = require('spec.helpers')

local commands = require('diffs.commands')
local diffspec = require('diffs.spec')
local git = require('diffs.git')
local runtime = require('diffs.runtime')

local saved_git = {}
local saved_runtime_attach
local saved_schedule
local saved_systemlist
local test_buffers = {}

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

local function restore_mocks()
  for k, v in pairs(saved_git) do
    git[k] = v
  end
  saved_git = {}
  if saved_runtime_attach then
    runtime.attach = saved_runtime_attach
    saved_runtime_attach = nil
  end
  if saved_schedule then
    vim.schedule = saved_schedule
    saved_schedule = nil
  end
  if saved_systemlist then
    vim.fn.systemlist = saved_systemlist
    saved_systemlist = nil
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

describe('commands', function()
  after_each(function()
    restore_mocks()
    cleanup_buffers()
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
      local lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)

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
      assert.is_true(diff_hunks[1].actionable)
      assert.are.equal('worktree', diff_hunks[1].mutation_target)
      assert.is_true(helpers.has_keymap(diff_buf, ']c'))
      assert.is_true(helpers.has_keymap(diff_buf, '[c'))
      assert.is_true(helpers.has_keymap(diff_buf, '<CR>'))
      assert.is_true(helpers.has_keymap(diff_buf, 'o'))
      assert.is_true(helpers.has_keymap(diff_buf, 'do'))
      assert.is_true(helpers.has_keymap(diff_buf, 'dp'))
      assert.are.equal('diff --git a/lua/foo.lua b/lua/foo.lua', lines[1])
      assert.is_true(table.concat(lines, '\n'):find('+local x = 1', 1, true) ~= nil)
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
      local lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)

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
      local lines = vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false)

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
      assert.are.equal('worktree', diff_hunks[1].mutation_target)
      assert.are.equal('diff --git a/lua/foo.lua b/lua/foo.lua', lines[1])
      assert.are.equal('--- a/lua/foo.lua', lines[2])
      assert.are.equal('+++ b/lua/foo.lua', lines[3])
      assert.is_true(table.concat(lines, '\n'):find('+local x = 1', 1, true) ~= nil)
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
      assert.is_true(helpers.has_keymap(diff_buf, 'do'))
      assert.is_true(helpers.has_keymap(diff_buf, 'dp'))
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
      assert.is_true(helpers.has_keymap(diff_buf, 'do'))
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
      local text = table.concat(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false), '\n')
      assert.is_true(text:find('new file mode 100644', 1, true) ~= nil)
      assert.is_true(text:find('--- /dev/null', 1, true) ~= nil)
      local diff_hunks = vim.api.nvim_buf_get_var(diff_buf, 'diffs_hunks')
      assert.are.equal(1, #diff_hunks)
      assert.are.equal('worktree', diff_hunks[1].mutation_target)
      assert.is_true(helpers.has_keymap(diff_buf, 'do'))
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
      local text = table.concat(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false), '\n')
      assert.is_true(text:find('new file mode 100644', 1, true) ~= nil)
      assert.is_true(text:find('--- /dev/null', 1, true) ~= nil)
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
      local text = table.concat(vim.api.nvim_buf_get_lines(diff_buf, 0, -1, false), '\n')
      assert.is_true(text:find('deleted file mode 100644', 1, true) ~= nil)
      assert.is_true(text:find('+++ /dev/null', 1, true) ~= nil)
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
