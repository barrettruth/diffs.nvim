require('spec.helpers')

local commands = require('diffs.commands')
local git = require('diffs.git')

local saved_git = {}
local saved_systemlist
local test_buffers = {}

local function mock_repo_root(fn)
  saved_git.get_repo_root = git.get_repo_root
  git.get_repo_root = fn
end

local function mock_systemlist(fn)
  saved_systemlist = vim.fn.systemlist
  vim.fn.systemlist = function(cmd)
    local result = fn(cmd)
    saved_systemlist({ 'true' })
    return result
  end
end

local function restore_mocks()
  for k, v in pairs(saved_git) do
    git[k] = v
  end
  saved_git = {}
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

      local bufnr = commands.greview({
        base = 'origin/main',
        target = 'refs/forge/pr/42',
        mode = 'merge-base',
        repo = '/tmp/repo',
      })
      table.insert(test_buffers, bufnr)
      vim.wait(10, function()
        return false
      end)

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
