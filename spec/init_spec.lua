require('spec.helpers')
local diffs = require('diffs')

describe('diffs', function()
  describe('vim.g.diffs config', function()
    after_each(function()
      vim.g.diffs = nil
    end)

    it('accepts nil config', function()
      vim.g.diffs = nil
      assert.has_no.errors(function()
        diffs.attach()
      end)
    end)

    it('accepts empty config', function()
      vim.g.diffs = {}
      assert.has_no.errors(function()
        diffs.attach()
      end)
    end)

    it('accepts full config', function()
      vim.g.diffs = {
        debug = true,
        hide_prefix = false,
        highlights = {
          background = true,
          gutter = true,
          treesitter = {
            enabled = true,
            max_lines = 1000,
          },
          vim = {
            enabled = false,
            max_lines = 200,
          },
        },
      }
      assert.has_no.errors(function()
        diffs.attach()
      end)
    end)

    it('accepts partial config', function()
      vim.g.diffs = {
        hide_prefix = true,
      }
      assert.has_no.errors(function()
        diffs.attach()
      end)
    end)
  end)

  describe('attach', function()
    local function create_buffer(lines)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
      return bufnr
    end

    local function delete_buffer(bufnr)
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end

    it('does not error on empty buffer', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        diffs.attach(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('does not error on buffer with content', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      assert.has_no.errors(function()
        diffs.attach(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('is idempotent', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        diffs.attach(bufnr)
        diffs.attach(bufnr)
        diffs.attach(bufnr)
      end)
      delete_buffer(bufnr)
    end)
  end)

  describe('refresh', function()
    local function create_buffer(lines)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
      return bufnr
    end

    local function delete_buffer(bufnr)
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end

    it('does not error on unattached buffer', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        diffs.refresh(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('does not error on attached buffer', function()
      local bufnr = create_buffer({})
      diffs.attach(bufnr)
      assert.has_no.errors(function()
        diffs.refresh(bufnr)
      end)
      delete_buffer(bufnr)
    end)
  end)

  describe('is_fugitive_buffer', function()
    it('returns true for fugitive:// URLs', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, 'fugitive:///path/to/repo/.git//abc123:file.lua')
      assert.is_true(diffs.is_fugitive_buffer(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns false for normal paths', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, '/home/user/project/file.lua')
      assert.is_false(diffs.is_fugitive_buffer(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns false for empty buffer names', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      assert.is_false(diffs.is_fugitive_buffer(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('find_visible_hunks', function()
    local find_visible_hunks = diffs._test.find_visible_hunks

    local function make_hunk(start_row, end_row, opts)
      local lines = {}
      for i = 1, end_row - start_row + 1 do
        lines[i] = 'line' .. i
      end
      local h = { start_line = start_row + 1, lines = lines }
      if opts and opts.header_start_line then
        h.header_start_line = opts.header_start_line
      end
      return h
    end

    it('returns (0, 0) for empty hunk list', function()
      local first, last = find_visible_hunks({}, 0, 50)
      assert.are.equal(0, first)
      assert.are.equal(0, last)
    end)

    it('finds single hunk fully inside viewport', function()
      local h = make_hunk(5, 10)
      local first, last = find_visible_hunks({ h }, 0, 50)
      assert.are.equal(1, first)
      assert.are.equal(1, last)
    end)

    it('returns (0, 0) for single hunk fully above viewport', function()
      local h = make_hunk(5, 10)
      local first, last = find_visible_hunks({ h }, 20, 50)
      assert.are.equal(0, first)
      assert.are.equal(0, last)
    end)

    it('returns (0, 0) for single hunk fully below viewport', function()
      local h = make_hunk(50, 60)
      local first, last = find_visible_hunks({ h }, 0, 20)
      assert.are.equal(0, first)
      assert.are.equal(0, last)
    end)

    it('finds single hunk partially visible at top edge', function()
      local h = make_hunk(5, 15)
      local first, last = find_visible_hunks({ h }, 10, 30)
      assert.are.equal(1, first)
      assert.are.equal(1, last)
    end)

    it('finds single hunk partially visible at bottom edge', function()
      local h = make_hunk(25, 35)
      local first, last = find_visible_hunks({ h }, 10, 30)
      assert.are.equal(1, first)
      assert.are.equal(1, last)
    end)

    it('finds subset of visible hunks', function()
      local h1 = make_hunk(5, 10)
      local h2 = make_hunk(25, 30)
      local h3 = make_hunk(55, 60)
      local first, last = find_visible_hunks({ h1, h2, h3 }, 20, 40)
      assert.are.equal(2, first)
      assert.are.equal(2, last)
    end)

    it('finds all hunks when all are visible', function()
      local h1 = make_hunk(5, 10)
      local h2 = make_hunk(15, 20)
      local h3 = make_hunk(25, 30)
      local first, last = find_visible_hunks({ h1, h2, h3 }, 0, 50)
      assert.are.equal(1, first)
      assert.are.equal(3, last)
    end)

    it('returns (0, 0) when no hunks are visible', function()
      local h1 = make_hunk(5, 10)
      local h2 = make_hunk(15, 20)
      local first, last = find_visible_hunks({ h1, h2 }, 30, 50)
      assert.are.equal(0, first)
      assert.are.equal(0, last)
    end)

    it('uses header_start_line for top boundary', function()
      local h = make_hunk(5, 10, { header_start_line = 4 })
      local first, last = find_visible_hunks({ h }, 0, 50)
      assert.are.equal(1, first)
      assert.are.equal(1, last)
    end)

    it('finds both adjacent hunks at viewport edge', function()
      local h1 = make_hunk(10, 20)
      local h2 = make_hunk(20, 30)
      local first, last = find_visible_hunks({ h1, h2 }, 15, 25)
      assert.are.equal(1, first)
      assert.are.equal(2, last)
    end)
  end)

  describe('hunk_cache', function()
    local function create_buffer(lines)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
      return bufnr
    end

    local function delete_buffer(bufnr)
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end

    it('creates entry on attach', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.is_table(entry.hunks)
      assert.is_number(entry.tick)
      assert.is_true(entry.tick >= 0)
      delete_buffer(bufnr)
    end)

    it('is idempotent on repeated attach', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local entry1 = diffs._test.hunk_cache[bufnr]
      local tick1 = entry1.tick
      local hunks1 = entry1.hunks
      diffs._test.ensure_cache(bufnr)
      local entry2 = diffs._test.hunk_cache[bufnr]
      assert.are.equal(tick1, entry2.tick)
      assert.are.equal(hunks1, entry2.hunks)
      delete_buffer(bufnr)
    end)

    it('marks stale on invalidate', function()
      local bufnr = create_buffer({})
      diffs.attach(bufnr)
      diffs._test.invalidate_cache(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.are.equal(-1, entry.tick)
      assert.is_true(entry.pending_clear)
      delete_buffer(bufnr)
    end)

    it('evicts on buffer wipeout', function()
      local bufnr = create_buffer({})
      diffs.attach(bufnr)
      assert.is_not_nil(diffs._test.hunk_cache[bufnr])
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(diffs._test.hunk_cache[bufnr])
    end)

    it('detects content change via tick', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local tick_before = diffs._test.hunk_cache[bufnr].tick
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '+local z = 3' })
      diffs._test.ensure_cache(bufnr)
      local tick_after = diffs._test.hunk_cache[bufnr].tick
      assert.is_true(tick_after > tick_before)
      delete_buffer(bufnr)
    end)
  end)

  describe('diff mode', function()
    local function create_diff_window()
      vim.cmd('new')
      local win = vim.api.nvim_get_current_win()
      local buf = vim.api.nvim_get_current_buf()
      vim.wo[win].diff = true
      return win, buf
    end

    local function close_window(win)
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end

    describe('attach_diff', function()
      it('applies winhighlight to diff windows', function()
        local win, _ = create_diff_window()
        diffs.attach_diff()

        local whl = vim.api.nvim_get_option_value('winhighlight', { win = win })
        assert.is_not_nil(whl:match('DiffAdd:DiffsDiffAdd'))
        assert.is_not_nil(whl:match('DiffDelete:DiffsDiffDelete'))

        close_window(win)
      end)

      it('is idempotent', function()
        local win, _ = create_diff_window()
        assert.has_no.errors(function()
          diffs.attach_diff()
          diffs.attach_diff()
          diffs.attach_diff()
        end)

        local whl = vim.api.nvim_get_option_value('winhighlight', { win = win })
        assert.is_not_nil(whl:match('DiffAdd:DiffsDiffAdd'))

        close_window(win)
      end)

      it('applies to multiple diff windows', function()
        local win1, _ = create_diff_window()
        local win2, _ = create_diff_window()
        diffs.attach_diff()

        local whl1 = vim.api.nvim_get_option_value('winhighlight', { win = win1 })
        local whl2 = vim.api.nvim_get_option_value('winhighlight', { win = win2 })
        assert.is_not_nil(whl1:match('DiffAdd:DiffsDiffAdd'))
        assert.is_not_nil(whl2:match('DiffAdd:DiffsDiffAdd'))

        close_window(win1)
        close_window(win2)
      end)

      it('ignores non-diff windows', function()
        vim.cmd('new')
        local non_diff_win = vim.api.nvim_get_current_win()

        local diff_win, _ = create_diff_window()
        diffs.attach_diff()

        local non_diff_whl = vim.api.nvim_get_option_value('winhighlight', { win = non_diff_win })
        local diff_whl = vim.api.nvim_get_option_value('winhighlight', { win = diff_win })

        assert.are.equal('', non_diff_whl)
        assert.is_not_nil(diff_whl:match('DiffAdd:DiffsDiffAdd'))

        close_window(non_diff_win)
        close_window(diff_win)
      end)
    end)

    describe('detach_diff', function()
      it('clears winhighlight from tracked windows', function()
        local win, _ = create_diff_window()
        diffs.attach_diff()
        diffs.detach_diff()

        local whl = vim.api.nvim_get_option_value('winhighlight', { win = win })
        assert.are.equal('', whl)

        close_window(win)
      end)

      it('does not error when no windows are tracked', function()
        assert.has_no.errors(function()
          diffs.detach_diff()
        end)
      end)

      it('handles already-closed windows gracefully', function()
        local win, _ = create_diff_window()
        diffs.attach_diff()
        close_window(win)

        assert.has_no.errors(function()
          diffs.detach_diff()
        end)
      end)

      it('clears all tracked windows', function()
        local win1, _ = create_diff_window()
        local win2, _ = create_diff_window()
        diffs.attach_diff()
        diffs.detach_diff()

        local whl1 = vim.api.nvim_get_option_value('winhighlight', { win = win1 })
        local whl2 = vim.api.nvim_get_option_value('winhighlight', { win = win2 })
        assert.are.equal('', whl1)
        assert.are.equal('', whl2)

        close_window(win1)
        close_window(win2)
      end)
    end)
  end)
end)
