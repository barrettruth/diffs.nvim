local conflict = require('diffs.conflict')
local helpers = require('spec.helpers')

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

local function create_file_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  return bufnr
end

local function get_extmarks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, conflict.get_namespace(), 0, -1, { details = true })
end

describe('conflict', function()
  describe('parse', function()
    it('parses a single conflict', function()
      local lines = {
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(1, #regions)
      assert.are.equal(0, regions[1].marker_ours)
      assert.are.equal(1, regions[1].ours_start)
      assert.are.equal(2, regions[1].ours_end)
      assert.are.equal(2, regions[1].marker_sep)
      assert.are.equal(3, regions[1].theirs_start)
      assert.are.equal(4, regions[1].theirs_end)
      assert.are.equal(4, regions[1].marker_theirs)
    end)

    it('parses multiple conflicts', function()
      local lines = {
        '<<<<<<< HEAD',
        'a',
        '=======',
        'b',
        '>>>>>>> feat',
        'normal line',
        '<<<<<<< HEAD',
        'c',
        '=======',
        'd',
        '>>>>>>> feat',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(2, #regions)
      assert.are.equal(0, regions[1].marker_ours)
      assert.are.equal(6, regions[2].marker_ours)
    end)

    it('parses diff3 format', function()
      local lines = {
        '<<<<<<< HEAD',
        'local x = 1',
        '||||||| base',
        'local x = 0',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(1, #regions)
      assert.are.equal(2, regions[1].marker_base)
      assert.are.equal(3, regions[1].base_start)
      assert.are.equal(4, regions[1].base_end)
    end)

    it('handles empty ours section', function()
      local lines = {
        '<<<<<<< HEAD',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(1, #regions)
      assert.are.equal(1, regions[1].ours_start)
      assert.are.equal(1, regions[1].ours_end)
    end)

    it('handles empty theirs section', function()
      local lines = {
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        '>>>>>>> feature',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(1, #regions)
      assert.are.equal(3, regions[1].theirs_start)
      assert.are.equal(3, regions[1].theirs_end)
    end)

    it('returns empty for no markers', function()
      local lines = { 'local x = 1', 'local y = 2' }
      local regions = conflict.parse(lines)
      assert.are.equal(0, #regions)
    end)

    it('discards malformed markers (no separator)', function()
      local lines = {
        '<<<<<<< HEAD',
        'local x = 1',
        '>>>>>>> feature',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(0, #regions)
    end)

    it('discards malformed markers (no end)', function()
      local lines = {
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(0, #regions)
    end)

    it('handles trailing text on marker lines', function()
      local lines = {
        '<<<<<<< HEAD (some text)',
        'local x = 1',
        '======= extra',
        'local x = 2',
        '>>>>>>> feature-branch/some-thing',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(1, #regions)
    end)

    it('handles empty base in diff3', function()
      local lines = {
        '<<<<<<< HEAD',
        'local x = 1',
        '||||||| base',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      }
      local regions = conflict.parse(lines)
      assert.are.equal(1, #regions)
      assert.are.equal(3, regions[1].base_start)
      assert.are.equal(3, regions[1].base_end)
    end)
  end)

  describe('highlighting', function()
    after_each(function()
      conflict.detach(vim.api.nvim_get_current_buf())
    end)

    it('applies extmarks for conflict regions', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config())

      local extmarks = get_extmarks(bufnr)
      assert.is_true(#extmarks > 0)

      local has_ours = false
      local has_theirs = false
      local has_marker = false
      for _, mark in ipairs(extmarks) do
        local hl = mark[4] and mark[4].hl_group
        if hl == 'DiffsConflictOurs' then
          has_ours = true
        end
        if hl == 'DiffsConflictTheirs' then
          has_theirs = true
        end
        if hl == 'DiffsConflictMarker' then
          has_marker = true
        end
      end
      assert.is_true(has_ours)
      assert.is_true(has_theirs)
      assert.is_true(has_marker)

      helpers.delete_buffer(bufnr)
    end)

    it('applies virtual text when enabled', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config({ show_virtual_text = true }))

      local extmarks = get_extmarks(bufnr)
      local virt_text_count = 0
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          virt_text_count = virt_text_count + 1
        end
      end
      assert.are.equal(2, virt_text_count)

      helpers.delete_buffer(bufnr)
    end)

    it('does not apply virtual text when disabled', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config({ show_virtual_text = false }))

      local extmarks = get_extmarks(bufnr)
      local virt_text_count = 0
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          virt_text_count = virt_text_count + 1
        end
      end
      assert.are.equal(0, virt_text_count)

      helpers.delete_buffer(bufnr)
    end)

    it('applies number_hl_group to content lines', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config())

      local extmarks = get_extmarks(bufnr)
      local has_ours_nr = false
      local has_theirs_nr = false
      for _, mark in ipairs(extmarks) do
        local nr = mark[4] and mark[4].number_hl_group
        if nr == 'DiffsConflictOursNr' then
          has_ours_nr = true
        end
        if nr == 'DiffsConflictTheirsNr' then
          has_theirs_nr = true
        end
      end
      assert.is_true(has_ours_nr)
      assert.is_true(has_theirs_nr)

      helpers.delete_buffer(bufnr)
    end)

    it('highlights base region in diff3', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '||||||| base',
        'local x = 0',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config())

      local extmarks = get_extmarks(bufnr)
      local has_base = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsConflictBase' then
          has_base = true
          break
        end
      end
      assert.is_true(has_base)

      helpers.delete_buffer(bufnr)
    end)

    it('clears extmarks on detach', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config())
      assert.is_true(#get_extmarks(bufnr) > 0)

      conflict.detach(bufnr)
      assert.are.equal(0, #get_extmarks(bufnr))

      helpers.delete_buffer(bufnr)
    end)
  end)

  describe('resolution', function()
    local function make_conflict_buffer()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })
      vim.api.nvim_set_current_buf(bufnr)
      return bufnr
    end

    it('resolve_ours keeps ours content', function()
      local bufnr = make_conflict_buffer()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      conflict.resolve_ours(bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal('local x = 1', lines[1])

      helpers.delete_buffer(bufnr)
    end)

    it('resolve_theirs keeps theirs content', function()
      local bufnr = make_conflict_buffer()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      conflict.resolve_theirs(bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal('local x = 2', lines[1])

      helpers.delete_buffer(bufnr)
    end)

    it('resolve_both keeps ours then theirs', function()
      local bufnr = make_conflict_buffer()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      conflict.resolve_both(bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(2, #lines)
      assert.are.equal('local x = 1', lines[1])
      assert.are.equal('local x = 2', lines[2])

      helpers.delete_buffer(bufnr)
    end)

    it('resolve_none removes entire block', function()
      local bufnr = make_conflict_buffer()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      conflict.resolve_none(bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal('', lines[1])

      helpers.delete_buffer(bufnr)
    end)

    it('does nothing when cursor is outside conflict', function()
      local bufnr = create_file_buffer({
        'normal line',
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      conflict.resolve_ours(bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(6, #lines)

      helpers.delete_buffer(bufnr)
    end)

    it('resolves one conflict among multiple', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'a',
        '=======',
        'b',
        '>>>>>>> feat',
        'middle',
        '<<<<<<< HEAD',
        'c',
        '=======',
        'd',
        '>>>>>>> feat',
      })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      conflict.resolve_ours(bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('a', lines[1])
      assert.are.equal('middle', lines[2])
      assert.are.equal('<<<<<<< HEAD', lines[3])

      helpers.delete_buffer(bufnr)
    end)

    it('resolve_ours with empty ours section', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      conflict.resolve_ours(bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal('', lines[1])

      helpers.delete_buffer(bufnr)
    end)

    it('handles diff3 resolution (ignores base)', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '||||||| base',
        'local x = 0',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      conflict.resolve_theirs(bufnr, default_config())

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal(1, #lines)
      assert.are.equal('local x = 2', lines[1])

      helpers.delete_buffer(bufnr)
    end)
  end)

  describe('navigation', function()
    it('goto_next jumps to next conflict', function()
      local bufnr = create_file_buffer({
        'normal',
        '<<<<<<< HEAD',
        'a',
        '=======',
        'b',
        '>>>>>>> feat',
        'middle',
        '<<<<<<< HEAD',
        'c',
        '=======',
        'd',
        '>>>>>>> feat',
      })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      conflict.goto_next(bufnr)
      assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])

      conflict.goto_next(bufnr)
      assert.are.equal(8, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(bufnr)
    end)

    it('goto_next wraps to first conflict', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'a',
        '=======',
        'b',
        '>>>>>>> feat',
      })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 5, 0 })

      conflict.goto_next(bufnr)
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(bufnr)
    end)

    it('goto_prev jumps to previous conflict', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'a',
        '=======',
        'b',
        '>>>>>>> feat',
        'middle',
        '<<<<<<< HEAD',
        'c',
        '=======',
        'd',
        '>>>>>>> feat',
        'end',
      })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 12, 0 })

      conflict.goto_prev(bufnr)
      assert.are.equal(7, vim.api.nvim_win_get_cursor(0)[1])

      conflict.goto_prev(bufnr)
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(bufnr)
    end)

    it('goto_prev wraps to last conflict', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'a',
        '=======',
        'b',
        '>>>>>>> feat',
      })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      conflict.goto_prev(bufnr)
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(bufnr)
    end)

    it('goto_next does nothing with no conflicts', function()
      local bufnr = create_file_buffer({ 'normal line' })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      conflict.goto_next(bufnr)
      assert.are.equal(1, vim.api.nvim_win_get_cursor(0)[1])

      helpers.delete_buffer(bufnr)
    end)
  end)

  describe('lifecycle', function()
    it('attach is idempotent', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'a',
        '=======',
        'b',
        '>>>>>>> feat',
      })
      local cfg = default_config()
      conflict.attach(bufnr, cfg)
      local count1 = #get_extmarks(bufnr)
      conflict.attach(bufnr, cfg)
      local count2 = #get_extmarks(bufnr)
      assert.are.equal(count1, count2)
      conflict.detach(bufnr)
      helpers.delete_buffer(bufnr)
    end)

    it('skips non-file buffers', function()
      local bufnr = helpers.create_buffer({
        '<<<<<<< HEAD',
        'a',
        '=======',
        'b',
        '>>>>>>> feat',
      })
      vim.api.nvim_set_option_value('buftype', 'nofile', { buf = bufnr })

      conflict.attach(bufnr, default_config())
      assert.are.equal(0, #get_extmarks(bufnr))

      helpers.delete_buffer(bufnr)
    end)

    it('skips buffers without conflict markers', function()
      local bufnr = create_file_buffer({ 'local x = 1', 'local y = 2' })

      conflict.attach(bufnr, default_config())
      assert.are.equal(0, #get_extmarks(bufnr))

      helpers.delete_buffer(bufnr)
    end)

    it('re-highlights when markers return after resolution', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })
      vim.api.nvim_set_current_buf(bufnr)
      local cfg = default_config()
      conflict.attach(bufnr, cfg)

      assert.is_true(#get_extmarks(bufnr) > 0)

      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      conflict.resolve_ours(bufnr, cfg)
      assert.are.equal(0, #get_extmarks(bufnr))

      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })

      assert.is_true(#get_extmarks(bufnr) > 0)

      conflict.detach(bufnr)
      helpers.delete_buffer(bufnr)
    end)

    it('detaches after last conflict resolved', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })
      vim.api.nvim_set_current_buf(bufnr)
      conflict.attach(bufnr, default_config())

      assert.is_true(#get_extmarks(bufnr) > 0)

      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      conflict.resolve_ours(bufnr, default_config())

      assert.are.equal(0, #get_extmarks(bufnr))

      helpers.delete_buffer(bufnr)
    end)
  end)

  describe('virtual text formatting', function()
    after_each(function()
      conflict.detach(vim.api.nvim_get_current_buf())
    end)

    it('includes keymap hints in default virtual text', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config())

      local extmarks = get_extmarks(bufnr)
      local labels = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          table.insert(labels, mark[4].virt_text[1][1])
        end
      end
      assert.are.equal(2, #labels)
      assert.is_truthy(labels[1]:find('current'))
      assert.is_truthy(labels[1]:find('doo'))
      assert.is_truthy(labels[2]:find('incoming'))
      assert.is_truthy(labels[2]:find('dot'))

      helpers.delete_buffer(bufnr)
    end)

    it('omits keymap from label when keymap is false', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config({ keymaps = { ours = false, theirs = false } }))

      local extmarks = get_extmarks(bufnr)
      local labels = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          table.insert(labels, mark[4].virt_text[1][1])
        end
      end
      assert.are.equal(2, #labels)
      assert.are.equal(' (current)', labels[1])
      assert.are.equal(' (incoming)', labels[2])

      helpers.delete_buffer(bufnr)
    end)

    it('uses custom format_virtual_text function', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(
        bufnr,
        default_config({
          format_virtual_text = function(side)
            return side == 'ours' and 'OURS' or 'THEIRS'
          end,
        })
      )

      local extmarks = get_extmarks(bufnr)
      local labels = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          table.insert(labels, mark[4].virt_text[1][1])
        end
      end
      assert.are.equal(2, #labels)
      assert.are.equal(' (OURS)', labels[1])
      assert.are.equal(' (THEIRS)', labels[2])

      helpers.delete_buffer(bufnr)
    end)

    it('hides label when format_virtual_text returns nil', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(
        bufnr,
        default_config({
          format_virtual_text = function()
            return nil
          end,
        })
      )

      local extmarks = get_extmarks(bufnr)
      local virt_text_count = 0
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text then
          virt_text_count = virt_text_count + 1
        end
      end
      assert.are.equal(0, virt_text_count)

      helpers.delete_buffer(bufnr)
    end)
  end)

  describe('action lines', function()
    after_each(function()
      conflict.detach(vim.api.nvim_get_current_buf())
    end)

    it('adds virt_lines when show_actions is true', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(bufnr, default_config({ show_actions = true }))

      local extmarks = get_extmarks(bufnr)
      local virt_lines_count = 0
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_lines then
          virt_lines_count = virt_lines_count + 1
        end
      end
      assert.are.equal(1, virt_lines_count)

      helpers.delete_buffer(bufnr)
    end)

    it('omits disabled keymaps from action line', function()
      local bufnr = create_file_buffer({
        '<<<<<<< HEAD',
        'local x = 1',
        '=======',
        'local x = 2',
        '>>>>>>> feature',
      })

      conflict.attach(
        bufnr,
        default_config({ show_actions = true, keymaps = { both = false, none = false } })
      )

      local extmarks = get_extmarks(bufnr)
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_lines then
          local line = mark[4].virt_lines[1]
          local text = ''
          for _, chunk in ipairs(line) do
            text = text .. chunk[1]
          end
          assert.is_truthy(text:find('Current'))
          assert.is_truthy(text:find('Incoming'))
          assert.is_falsy(text:find('Both'))
          assert.is_falsy(text:find('None'))
        end
      end

      helpers.delete_buffer(bufnr)
    end)
  end)
end)
