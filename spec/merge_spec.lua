local helpers = require('spec.helpers')
local merge = require('diffs.merge')

local function default_config(overrides)
  local cfg = {
    enabled = true,
    disable_diagnostics = false,
    show_virtual_text = true,
    show_actions = false,
    keymaps = {
      ours = 'doo',
      theirs = 'dot',
      both = 'dob',
      none = 'don',
      next = ']x',
      prev = '[x',
    },
  }
  if overrides then
    cfg = vim.tbl_deep_extend('force', cfg, overrides)
  end
  return cfg
end

local function create_diff_buffer(lines, working_path)
  local bufnr = helpers.create_buffer(lines)
  if working_path then
    vim.api.nvim_buf_set_var(bufnr, 'diffs_working_path', working_path)
  end
  return bufnr
end

local function create_working_buffer(lines, name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if name then
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  return bufnr
end

describe('merge', function()
  describe('parse_hunks', function()
    it('parses a single hunk', function()
      local bufnr = helpers.create_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,3 @@',
        ' local M = {}',
        '-local x = 1',
        '+local x = 2',
        ' return M',
      })

      local hunks = merge.parse_hunks(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.equal(3, hunks[1].start_line)
      assert.are.equal(7, hunks[1].end_line)
      assert.are.same({ 'local x = 1' }, hunks[1].del_lines)
      assert.are.same({ 'local x = 2' }, hunks[1].add_lines)

      helpers.delete_buffer(bufnr)
    end)

    it('parses multiple hunks', function()
      local bufnr = helpers.create_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,3 @@',
        ' local M = {}',
        '-local x = 1',
        '+local x = 2',
        ' return M',
        '@@ -10,3 +10,3 @@',
        ' function M.foo()',
        '-  return 1',
        '+  return 2',
        ' end',
      })

      local hunks = merge.parse_hunks(bufnr)
      assert.are.equal(2, #hunks)
      assert.are.equal(3, hunks[1].start_line)
      assert.are.equal(8, hunks[2].start_line)

      helpers.delete_buffer(bufnr)
    end)

    it('parses add-only hunk', function()
      local bufnr = helpers.create_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      })

      local hunks = merge.parse_hunks(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.same({}, hunks[1].del_lines)
      assert.are.same({ 'local new = true' }, hunks[1].add_lines)

      helpers.delete_buffer(bufnr)
    end)

    it('parses delete-only hunk', function()
      local bufnr = helpers.create_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,2 @@',
        ' local M = {}',
        '-local old = false',
        ' return M',
      })

      local hunks = merge.parse_hunks(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.same({ 'local old = false' }, hunks[1].del_lines)
      assert.are.same({}, hunks[1].add_lines)

      helpers.delete_buffer(bufnr)
    end)

    it('returns empty for buffer with no hunks', function()
      local bufnr = helpers.create_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
      })

      local hunks = merge.parse_hunks(bufnr)
      assert.are.equal(0, #hunks)

      helpers.delete_buffer(bufnr)
    end)
  end)

  describe('match_hunk_to_conflict', function()
    it('matches hunk to conflict region', function()
      local working_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, '/tmp/diffs_test_match.lua')

      local hunk = {
        index = 1,
        start_line = 3,
        end_line = 7,
        del_lines = { 'local x = 1' },
        add_lines = { 'local x = 2' },
      }

      local region = merge.match_hunk_to_conflict(hunk, working_bufnr)
      assert.is_not_nil(region)
      assert.are.equal(0, region.marker_ours)

      helpers.delete_buffer(working_bufnr)
    end)

    it('returns nil for auto-merged content', function()
      local working_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, '/tmp/diffs_test_auto.lua')

      local hunk = {
        index = 1,
        start_line = 3,
        end_line = 7,
        del_lines = { 'local y = 3' },
        add_lines = { 'local y = 4' },
      }

      local region = merge.match_hunk_to_conflict(hunk, working_bufnr)
      assert.is_nil(region)

      helpers.delete_buffer(working_bufnr)
    end)

    it('matches with empty ours section', function()
      local working_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, '/tmp/diffs_test_empty_ours.lua')

      local hunk = {
        index = 1,
        start_line = 3,
        end_line = 5,
        del_lines = {},
        add_lines = { 'local x = 2' },
      }

      local region = merge.match_hunk_to_conflict(hunk, working_bufnr)
      assert.is_not_nil(region)

      helpers.delete_buffer(working_bufnr)
    end)

    it('matches correct region among multiple conflicts', function()
      local working_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local a = 1',
        '=======',
        'local a = 2',
        '>>>>>>> feature',
        'middle',
        '<<<<<<< HEAD',
        'local b = 3',
        '=======',
        'local b = 4',
        '>>>>>>> feature',
      }, '/tmp/diffs_test_multi.lua')

      local hunk = {
        index = 2,
        start_line = 8,
        end_line = 12,
        del_lines = { 'local b = 3' },
        add_lines = { 'local b = 4' },
      }

      local region = merge.match_hunk_to_conflict(hunk, working_bufnr)
      assert.is_not_nil(region)
      assert.are.equal(6, region.marker_ours)

      helpers.delete_buffer(working_bufnr)
    end)

    it('matches with diff3 format', function()
      local working_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '||||||| base',
        'local x = 0',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, '/tmp/diffs_test_diff3.lua')

      local hunk = {
        index = 1,
        start_line = 3,
        end_line = 7,
        del_lines = { 'local x = 1' },
        add_lines = { 'local x = 2' },
      }

      local region = merge.match_hunk_to_conflict(hunk, working_bufnr)
      assert.is_not_nil(region)
      assert.are.equal(2, region.marker_base)

      helpers.delete_buffer(working_bufnr)
    end)
  end)

  describe('resolution', function()
    local diff_bufnr, working_bufnr

    local function setup_buffers()
      local working_path = '/tmp/diffs_test_resolve.lua'
      working_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, working_path)

      diff_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      }, working_path)
      vim.api.nvim_set_current_buf(diff_bufnr)
    end

    local function cleanup()
      helpers.delete_buffer(diff_bufnr)
      helpers.delete_buffer(working_bufnr)
    end

    it('resolve_ours keeps ours content in working file', function()
      setup_buffers()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      merge.resolve_ours(diff_bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(working_bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal('local x = 1', lines[1])

      cleanup()
    end)

    it('resolve_theirs keeps theirs content in working file', function()
      setup_buffers()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      merge.resolve_theirs(diff_bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(working_bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal('local x = 2', lines[1])

      cleanup()
    end)

    it('resolve_both keeps ours then theirs in working file', function()
      setup_buffers()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      merge.resolve_both(diff_bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(working_bufnr, 0, -1, false)
      assert.are.equal(2, #lines)
      assert.are.equal('local x = 1', lines[1])
      assert.are.equal('local x = 2', lines[2])

      cleanup()
    end)

    it('resolve_none removes entire block from working file', function()
      setup_buffers()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      merge.resolve_none(diff_bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(working_bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal('', lines[1])

      cleanup()
    end)

    it('tracks resolved hunks', function()
      setup_buffers()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      assert.is_false(merge.is_resolved(diff_bufnr, 1))
      merge.resolve_ours(diff_bufnr, default_config())
      assert.is_true(merge.is_resolved(diff_bufnr, 1))

      cleanup()
    end)

    it('adds virtual text for resolved hunks', function()
      setup_buffers()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      merge.resolve_ours(diff_bufnr, default_config())

      local extmarks =
        vim.api.nvim_buf_get_extmarks(diff_bufnr, merge.get_namespace(), 0, -1, { details = true })
      local has_resolved_text = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          for _, chunk in ipairs(mark[4].virt_text) do
            if chunk[1]:match('resolved') then
              has_resolved_text = true
            end
          end
        end
      end
      assert.is_true(has_resolved_text)

      cleanup()
    end)

    it('notifies when hunk is already resolved', function()
      setup_buffers()
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      merge.resolve_ours(diff_bufnr, default_config())

      local notified = false
      local orig_notify = vim.notify
      vim.notify = function(msg)
        if msg:match('already resolved') then
          notified = true
        end
      end

      merge.resolve_ours(diff_bufnr, default_config())
      vim.notify = orig_notify

      assert.is_true(notified)

      cleanup()
    end)

    it('notifies when hunk does not match a conflict', function()
      local working_path = '/tmp/diffs_test_no_conflict.lua'
      local w_bufnr = create_working_buffer({
        'local y = 1',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      local notified = false
      local orig_notify = vim.notify
      vim.notify = function(msg)
        if msg:match('does not correspond') then
          notified = true
        end
      end

      merge.resolve_ours(d_bufnr, default_config())
      vim.notify = orig_notify

      assert.is_true(notified)

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)
  end)

  describe('navigation', function()
    it('goto_next jumps to next conflict hunk', function()
      local working_path = '/tmp/diffs_test_nav.lua'
      local w_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local a = 1',
        '=======',
        'local a = 2',
        '>>>>>>> feature',
        'middle',
        '<<<<<<< HEAD',
        'local b = 3',
        '=======',
        'local b = 4',
        '>>>>>>> feature',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local a = 1',
        '+local a = 2',
        '@@ -5,1 +5,1 @@',
        '-local b = 3',
        '+local b = 4',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      merge.goto_next(d_bufnr)
      assert.are.equal(4, vim.api.nvim_win_get_cursor(0)[1])

      merge.goto_next(d_bufnr)
      assert.are.equal(7, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)

    it('goto_next wraps around', function()
      local working_path = '/tmp/diffs_test_wrap.lua'
      local w_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 6, 0 })

      merge.goto_next(d_bufnr)
      assert.are.equal(4, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)

    it('goto_next notifies on wrap-around', function()
      local working_path = '/tmp/diffs_test_wrap_notify.lua'
      local w_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 6, 0 })

      local notified = false
      local orig_notify = vim.notify
      vim.notify = function(msg)
        if msg:match('wrapped to first hunk') then
          notified = true
        end
      end

      merge.goto_next(d_bufnr)
      vim.notify = orig_notify

      assert.is_true(notified)

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)

    it('goto_prev jumps to previous conflict hunk', function()
      local working_path = '/tmp/diffs_test_prev.lua'
      local w_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local a = 1',
        '=======',
        'local a = 2',
        '>>>>>>> feature',
        'middle',
        '<<<<<<< HEAD',
        'local b = 3',
        '=======',
        'local b = 4',
        '>>>>>>> feature',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local a = 1',
        '+local a = 2',
        '@@ -5,1 +5,1 @@',
        '-local b = 3',
        '+local b = 4',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 9, 0 })

      merge.goto_prev(d_bufnr)
      assert.are.equal(7, vim.api.nvim_win_get_cursor(0)[1])

      merge.goto_prev(d_bufnr)
      assert.are.equal(4, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)

    it('goto_prev wraps around', function()
      local working_path = '/tmp/diffs_test_prev_wrap.lua'
      local w_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      merge.goto_prev(d_bufnr)
      assert.are.equal(4, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)

    it('goto_prev notifies on wrap-around', function()
      local working_path = '/tmp/diffs_test_prev_wrap_notify.lua'
      local w_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      local notified = false
      local orig_notify = vim.notify
      vim.notify = function(msg)
        if msg:match('wrapped to last hunk') then
          notified = true
        end
      end

      merge.goto_prev(d_bufnr)
      vim.notify = orig_notify

      assert.is_true(notified)

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)

    it('skips resolved hunks', function()
      local working_path = '/tmp/diffs_test_skip_resolved.lua'
      local w_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local a = 1',
        '=======',
        'local a = 2',
        '>>>>>>> feature',
        'middle',
        '<<<<<<< HEAD',
        'local b = 3',
        '=======',
        'local b = 4',
        '>>>>>>> feature',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local a = 1',
        '+local a = 2',
        '@@ -5,1 +5,1 @@',
        '-local b = 3',
        '+local b = 4',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      merge.resolve_ours(d_bufnr, default_config())

      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      merge.goto_next(d_bufnr)
      assert.are.equal(7, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)
  end)

  describe('hunk hints', function()
    it('adds keymap hints on hunk header lines', function()
      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      })

      merge.setup_keymaps(d_bufnr, default_config())

      local extmarks =
        vim.api.nvim_buf_get_extmarks(d_bufnr, merge.get_namespace(), 0, -1, { details = true })
      local hint_marks = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          local text = ''
          for _, chunk in ipairs(mark[4].virt_text) do
            text = text .. chunk[1]
          end
          table.insert(hint_marks, { line = mark[2], text = text })
        end
      end
      assert.are.equal(1, #hint_marks)
      assert.are.equal(3, hint_marks[1].line)
      assert.is_truthy(hint_marks[1].text:find('doo'))
      assert.is_truthy(hint_marks[1].text:find('dot'))

      helpers.delete_buffer(d_bufnr)
    end)
  end)

  describe('setup_keymaps', function()
    it('clears resolved state on re-init', function()
      local working_path = '/tmp/diffs_test_reinit.lua'
      local w_bufnr = create_working_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }, working_path)

      local d_bufnr = create_diff_buffer({
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      }, working_path)
      vim.api.nvim_set_current_buf(d_bufnr)
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      local cfg = default_config()
      merge.resolve_ours(d_bufnr, cfg)
      assert.is_true(merge.is_resolved(d_bufnr, 1))

      local extmarks =
        vim.api.nvim_buf_get_extmarks(d_bufnr, merge.get_namespace(), 0, -1, { details = true })
      assert.is_true(#extmarks > 0)

      merge.setup_keymaps(d_bufnr, cfg)

      assert.is_false(merge.is_resolved(d_bufnr, 1))
      extmarks =
        vim.api.nvim_buf_get_extmarks(d_bufnr, merge.get_namespace(), 0, -1, { details = true })
      local resolved_count = 0
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          for _, chunk in ipairs(mark[4].virt_text) do
            if chunk[1]:match('resolved') then
              resolved_count = resolved_count + 1
            end
          end
        end
      end
      assert.are.equal(0, resolved_count)

      helpers.delete_buffer(d_bufnr)
      helpers.delete_buffer(w_bufnr)
    end)
  end)

  describe('fugitive integration', function()
    it('parse_file_line returns status for unmerged files', function()
      local fugitive = require('diffs.fugitive')
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'Unstaged (1)',
        'U  conflict.lua',
      })
      local filename, section, is_header, old_filename, status = fugitive.get_file_at_line(buf, 2)
      assert.are.equal('conflict.lua', filename)
      assert.are.equal('unstaged', section)
      assert.is_false(is_header)
      assert.is_nil(old_filename)
      assert.are.equal('U', status)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('walkback from hunk line propagates status', function()
      local fugitive = require('diffs.fugitive')
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'Unstaged (1)',
        'U  conflict.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
      })
      local _, _, _, _, status = fugitive.get_file_at_line(buf, 5)
      assert.are.equal('U', status)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
