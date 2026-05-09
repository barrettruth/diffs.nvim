local helpers = require('spec.helpers')

local diffspec = require('diffs.spec')
local hunks = require('diffs.hunks')

local function sample_lines()
  return {
    'diff --git a/lua/foo.lua b/lua/foo.lua',
    '--- a/lua/foo.lua',
    '+++ b/lua/foo.lua',
    '@@ -1,3 +1,4 @@',
    ' local a = 1',
    '-local b = 2',
    '+local b = 3',
    ' local c = 4',
    '+local d = 5',
  }
end

describe('diffs.hunks', function()
  describe('parse', function()
    it('builds hunk and line metadata for added, deleted, and context lines', function()
      local parsed = hunks.parse(sample_lines(), diffspec.index_to_worktree('lua/foo.lua'))

      assert.are.equal(1, #parsed)
      assert.are.equal('lua/foo.lua', parsed[1].file)
      assert.are.same({ start = 1, count = 3, finish = 3 }, parsed[1].old_range)
      assert.are.same({ start = 1, count = 4, finish = 4 }, parsed[1].new_range)
      assert.are.same({ start = 4, count = 6, finish = 9 }, parsed[1].buffer_range)
      assert.are.equal('@@ -1,3 +1,4 @@', parsed[1].header)
      assert.is_true(parsed[1].actionable)
      assert.are.equal('worktree', parsed[1].mutation_target)
      assert.are.same({ kind = 'index' }, parsed[1].edge.left)
      assert.are.same({ kind = 'worktree' }, parsed[1].edge.right)

      assert.are.equal('header', parsed[1].lines[1].kind)
      assert.are.equal(4, parsed[1].lines[1].lnum)
      assert.are.equal(1, parsed[1].lines[1].old_lnum)
      assert.are.equal(1, parsed[1].lines[1].new_lnum)

      assert.are.equal('context', parsed[1].lines[2].kind)
      assert.are.equal(1, parsed[1].lines[2].old_lnum)
      assert.are.equal(1, parsed[1].lines[2].new_lnum)

      assert.are.equal('delete', parsed[1].lines[3].kind)
      assert.are.equal(2, parsed[1].lines[3].old_lnum)
      assert.is_nil(parsed[1].lines[3].new_lnum)
      assert.are.equal(2, parsed[1].lines[3].source_lnum)

      assert.are.equal('add', parsed[1].lines[4].kind)
      assert.is_nil(parsed[1].lines[4].old_lnum)
      assert.are.equal(2, parsed[1].lines[4].new_lnum)

      assert.are.equal('add', parsed[1].lines[6].kind)
      assert.are.equal(4, parsed[1].lines[6].new_lnum)
    end)

    it('keeps no-newline markers inside the hunk as metadata lines', function()
      local parsed = hunks.parse({
        'diff --git a/foo.lua b/foo.lua',
        '--- a/foo.lua',
        '+++ b/foo.lua',
        '@@ -1 +1 @@',
        '-return 1',
        '\\ No newline at end of file',
        '+return 2',
        '\\ No newline at end of file',
      }, diffspec.index_to_worktree('foo.lua'))

      assert.are.same({ start = 4, count = 5, finish = 8 }, parsed[1].buffer_range)
      assert.are.equal('meta', parsed[1].lines[3].kind)
      assert.are.equal(6, parsed[1].lines[3].lnum)
      assert.are.equal('meta', parsed[1].lines[5].kind)
      assert.are.equal(8, parsed[1].lines[5].lnum)
    end)

    it('detects multiple hunks in one file', function()
      local parsed = hunks.parse({
        'diff --git a/foo.lua b/foo.lua',
        '--- a/foo.lua',
        '+++ b/foo.lua',
        '@@ -1 +1 @@',
        '-one',
        '+two',
        '@@ -10 +10 @@',
        '-ten',
        '+eleven',
      }, diffspec.index_to_worktree('foo.lua'))

      assert.are.equal(2, #parsed)
      assert.are.equal('foo.lua', parsed[1].file)
      assert.are.equal('foo.lua', parsed[2].file)
      assert.are.same({ start = 4, count = 3, finish = 6 }, parsed[1].buffer_range)
      assert.are.same({ start = 7, count = 3, finish = 9 }, parsed[2].buffer_range)
      assert.are.same({ start = 10, count = 1, finish = 10 }, parsed[2].old_range)
      assert.are.same({ start = 10, count = 1, finish = 10 }, parsed[2].new_range)
    end)

    it('detects hunks across multiple files', function()
      local parsed = hunks.parse({
        'diff --git a/foo.lua b/foo.lua',
        '--- a/foo.lua',
        '+++ b/foo.lua',
        '@@ -1 +1 @@',
        '-one',
        '+two',
        'diff --git a/bar.py b/bar.py',
        '--- a/bar.py',
        '+++ b/bar.py',
        '@@ -3 +3 @@',
        '-old',
        '+new',
      })

      assert.are.equal(2, #parsed)
      assert.are.equal('foo.lua', parsed[1].file)
      assert.are.equal('bar.py', parsed[2].file)
      assert.are.same({ start = 4, count = 3, finish = 6 }, parsed[1].buffer_range)
      assert.are.same({ start = 10, count = 3, finish = 12 }, parsed[2].buffer_range)
    end)

    it('preserves real top-level a and b directory names', function()
      local parsed = hunks.parse({
        'diff --git a/a/foo.lua b/a/foo.lua',
        '--- a/a/foo.lua',
        '+++ b/a/foo.lua',
        '@@ -1 +1 @@',
        '-old',
        '+new',
        'diff --git a/b/bar.lua b/b/bar.lua',
        '--- a/b/bar.lua',
        '+++ b/b/bar.lua',
        '@@ -1 +1 @@',
        '-old',
        '+new',
      })

      assert.are.equal('a/foo.lua', parsed[1].file)
      assert.are.equal('b/bar.lua', parsed[2].file)
    end)

    it('marks tree to tree hunks as read-only', function()
      local parsed =
        hunks.parse(sample_lines(), diffspec.rev_to_rev('HEAD~1', 'HEAD', 'lua/foo.lua'))

      assert.is_false(parsed[1].actionable)
      assert.is_nil(parsed[1].mutation_target)
      assert.are.same({ kind = 'tree', rev = 'HEAD~1' }, parsed[1].edge.left)
      assert.are.same({ kind = 'tree', rev = 'HEAD' }, parsed[1].edge.right)
    end)
  end)

  describe('lookup helpers', function()
    it('resolves cursor lines to hunks and hunk lines', function()
      local parsed = hunks.parse(sample_lines(), diffspec.index_to_worktree('lua/foo.lua'))

      assert.is_nil(hunks.hunk_at_line(parsed, 1))
      assert.are.equal(parsed[1], hunks.hunk_at_line(parsed, 4))
      assert.are.equal(parsed[1], hunks.hunk_at_line(parsed, 6))
      assert.are.equal('header', hunks.line_at(parsed, 4).kind)
      assert.are.equal('delete', hunks.line_at(parsed, 6).kind)
      assert.are.equal('context', hunks.line_at(parsed, 8).kind)
      assert.is_nil(hunks.line_at(parsed, 2))
    end)

    it('finds next and previous hunk boundaries', function()
      local parsed = hunks.parse({
        'diff --git a/foo.lua b/foo.lua',
        '--- a/foo.lua',
        '+++ b/foo.lua',
        '@@ -1 +1 @@',
        '-one',
        '+two',
        '@@ -10 +10 @@',
        '-ten',
        '+eleven',
      }, diffspec.index_to_worktree('foo.lua'))

      assert.are.equal(parsed[1], hunks.next_hunk(parsed, 1))
      assert.are.equal(parsed[2], hunks.next_hunk(parsed, 4))
      assert.is_nil(hunks.next_hunk(parsed, 7))
      assert.are.equal(parsed[1], hunks.prev_hunk(parsed, 6))
      assert.are.equal(parsed[1], hunks.prev_hunk(parsed, 7))
      assert.is_nil(hunks.prev_hunk(parsed, 4))
    end)

    it('maps hunks and lines to source file positions', function()
      local parsed = hunks.parse(sample_lines(), diffspec.index_to_worktree('lua/foo.lua'))

      assert.are.same({ path = 'lua/foo.lua', lnum = 1 }, hunks.source_line_for(parsed[1]))
      assert.are.same({ path = 'lua/foo.lua', lnum = 2 }, hunks.source_line_for(parsed[1].lines[3]))
      assert.are.same({ path = 'lua/foo.lua', lnum = 4 }, hunks.source_line_for(parsed[1].lines[6]))
    end)
  end)

  describe('navigation', function()
    local bufnr

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      bufnr = nil
    end)

    it('jumps between stored hunk boundaries with wrapping', function()
      local lines = {
        'diff --git a/foo.lua b/foo.lua',
        '--- a/foo.lua',
        '+++ b/foo.lua',
        '@@ -1 +1 @@',
        '-one',
        '+two',
        '@@ -10 +10 @@',
        '-ten',
        '+eleven',
      }
      local parsed = hunks.parse(lines, diffspec.index_to_worktree('foo.lua'))
      bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.api.nvim_buf_set_var(bufnr, 'diffs_hunks', parsed)
      vim.api.nvim_set_current_buf(bufnr)

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      hunks.goto_next(bufnr)
      assert.are.same({ 4, 0 }, vim.api.nvim_win_get_cursor(0))

      hunks.goto_next(bufnr)
      assert.are.same({ 7, 0 }, vim.api.nvim_win_get_cursor(0))

      hunks.goto_prev(bufnr)
      assert.are.same({ 4, 0 }, vim.api.nvim_win_get_cursor(0))
    end)
  end)

  describe('source opening', function()
    local source_buf
    local diff_buf
    local source_win
    local diff_win
    local saved_notify

    local function cleanup()
      if saved_notify then
        vim.notify = saved_notify
        saved_notify = nil
      end
      pcall(vim.cmd, 'only')
      helpers.delete_buffer(diff_buf)
      helpers.delete_buffer(source_buf)
      source_buf = nil
      diff_buf = nil
      source_win = nil
      diff_win = nil
    end

    local function create_source_window()
      source_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(source_buf, '/tmp/repo/lua/foo.lua')
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, {
        'local a = 1',
        'local b = 3',
        'local c = 4',
        'local d = 5',
      })
      vim.api.nvim_set_current_buf(source_buf)
      source_win = vim.api.nvim_get_current_win()
    end

    local function create_diff_window(diff_spec)
      local lines = sample_lines()
      diff_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, lines)
      vim.api.nvim_buf_set_var(diff_buf, 'diffs_hunks', hunks.parse(lines, diff_spec))
      vim.api.nvim_buf_set_var(diff_buf, 'diffs_repo_root', '/tmp/repo')
      vim.cmd('split')
      diff_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(diff_win, diff_buf)
    end

    after_each(cleanup)

    it('opens an existing worktree source window from an added line', function()
      create_source_window()
      create_diff_window(diffspec.index_to_worktree('lua/foo.lua'))

      vim.api.nvim_win_set_cursor(diff_win, { 7, 0 })

      assert.is_true(hunks.open_source(diff_buf))
      assert.are.equal(source_win, vim.api.nvim_get_current_win())
      assert.are.equal(source_buf, vim.api.nvim_get_current_buf())
      assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('maps deleted lines to the best worktree source line', function()
      create_source_window()
      create_diff_window(diffspec.rev_to_worktree('HEAD', 'lua/foo.lua'))

      vim.api.nvim_win_set_cursor(diff_win, { 6, 0 })

      assert.is_true(hunks.open_source(diff_buf))
      assert.are.equal(source_win, vim.api.nvim_get_current_win())
      assert.are.same({ 2, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('refuses index-backed hunks with a clear message', function()
      local notification
      saved_notify = vim.notify
      vim.notify = function(message, level)
        notification = { message = message, level = level }
      end
      create_source_window()
      create_diff_window(diffspec.head_to_index('lua/foo.lua'))

      vim.api.nvim_win_set_cursor(diff_win, { 7, 0 })

      assert.is_false(hunks.open_source(diff_buf))
      assert.are.equal(diff_win, vim.api.nvim_get_current_win())
      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(notification.message:find('index%-backed Gdiff hunk') ~= nil)
    end)

    it('refuses read-only tree-backed hunks with a clear message', function()
      local notification
      saved_notify = vim.notify
      vim.notify = function(message, level)
        notification = { message = message, level = level }
      end
      create_source_window()
      create_diff_window(diffspec.rev_to_rev('HEAD~1', 'HEAD', 'lua/foo.lua'))

      vim.api.nvim_win_set_cursor(diff_win, { 7, 0 })

      assert.is_false(hunks.open_source(diff_buf))
      assert.is_not_nil(notification)
      assert.are.equal(vim.log.levels.WARN, notification.level)
      assert.is_true(notification.message:find('read%-only tree%-backed Gdiff hunk') ~= nil)
    end)

    it('returns the resolved source location without opening it', function()
      create_source_window()
      create_diff_window(diffspec.index_to_worktree('lua/foo.lua'))

      vim.api.nvim_win_set_cursor(diff_win, { 9, 0 })

      assert.are.same(
        { path = '/tmp/repo/lua/foo.lua', lnum = 4 },
        hunks.source_at_cursor(diff_buf)
      )
    end)
  end)
end)
