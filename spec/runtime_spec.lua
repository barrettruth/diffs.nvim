require('spec.helpers')
local runtime = require('diffs.runtime')

describe('diffs.runtime', function()
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
        runtime.attach(bufnr)
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
        runtime.attach(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('is idempotent', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        runtime.attach(bufnr)
        runtime.attach(bufnr)
        runtime.attach(bufnr)
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
        runtime.refresh(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('does not error on attached buffer', function()
      local bufnr = create_buffer({})
      runtime.attach(bufnr)
      assert.has_no.errors(function()
        runtime.refresh(bufnr)
      end)
      delete_buffer(bufnr)
    end)
  end)

  describe('is_fugitive_buffer', function()
    it('returns true for fugitive:// URLs', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, 'fugitive:///path/to/repo/.git//abc123:file.lua')
      assert.is_true(runtime.is_fugitive_buffer(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns false for normal paths', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(bufnr, '/home/user/project/file.lua')
      assert.is_false(runtime.is_fugitive_buffer(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('returns false for empty buffer names', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      assert.is_false(runtime.is_fugitive_buffer(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('find_visible_hunks', function()
    local find_visible_hunks = runtime._test.find_visible_hunks

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
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
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
      runtime.attach(bufnr)
      local entry1 = runtime._test.hunk_cache[bufnr]
      local tick1 = entry1.tick
      local hunks1 = entry1.hunks
      runtime._test.ensure_cache(bufnr)
      local entry2 = runtime._test.hunk_cache[bufnr]
      assert.are.equal(tick1, entry2.tick)
      assert.are.equal(hunks1, entry2.hunks)
      delete_buffer(bufnr)
    end)

    it('marks stale on invalidate', function()
      local bufnr = create_buffer({})
      runtime.attach(bufnr)
      runtime._test.invalidate_cache(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.are.equal(-1, entry.tick)
      assert.is_true(entry.pending_clear)
      delete_buffer(bufnr)
    end)

    it('invalidate_attached eagerly clears extmarks and resets highlighted', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,1 @@',
        '-local x = 1',
        '+local x = 2',
      })
      runtime.attach(bufnr)
      local ns = vim.api.nvim_create_namespace('diffs')
      vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 0, {
        end_row = 2,
        end_col = 0,
        hl_group = 'DiffsDelete',
        hl_eol = true,
      })
      local entry = runtime._test.hunk_cache[bufnr]
      entry.highlighted = { [1] = true }
      entry.pending_clear = false

      runtime.invalidate_attached()

      assert.are.equal(0, #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
      assert.are.equal(0, vim.tbl_count(runtime._test.hunk_cache[bufnr].highlighted))
      assert.is_false(runtime._test.hunk_cache[bufnr].pending_clear)
      delete_buffer(bufnr)
    end)

    it('evicts on buffer wipeout', function()
      local bufnr = create_buffer({})
      runtime.attach(bufnr)
      assert.is_not_nil(runtime._test.hunk_cache[bufnr])
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(runtime._test.hunk_cache[bufnr])
    end)

    it('detects content change via tick', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      runtime.attach(bufnr)
      local tick_before = runtime._test.hunk_cache[bufnr].tick
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '+local z = 3' })
      runtime._test.ensure_cache(bufnr)
      local tick_after = runtime._test.hunk_cache[bufnr].tick
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
        runtime.attach_diff()

        local whl = vim.api.nvim_get_option_value('winhighlight', { win = win })
        assert.is_not_nil(whl:match('DiffAdd:DiffsDiffAdd'))
        assert.is_not_nil(whl:match('DiffDelete:DiffsDiffDelete'))

        close_window(win)
      end)

      it('is idempotent', function()
        local win, _ = create_diff_window()
        assert.has_no.errors(function()
          runtime.attach_diff()
          runtime.attach_diff()
          runtime.attach_diff()
        end)

        local whl = vim.api.nvim_get_option_value('winhighlight', { win = win })
        assert.is_not_nil(whl:match('DiffAdd:DiffsDiffAdd'))

        close_window(win)
      end)

      it('applies to multiple diff windows', function()
        local win1, _ = create_diff_window()
        local win2, _ = create_diff_window()
        runtime.attach_diff()

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
        runtime.attach_diff()

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
        runtime.attach_diff()
        runtime.detach_diff()

        local whl = vim.api.nvim_get_option_value('winhighlight', { win = win })
        assert.are.equal('', whl)

        close_window(win)
      end)

      it('does not error when no windows are tracked', function()
        assert.has_no.errors(function()
          runtime.detach_diff()
        end)
      end)

      it('handles already-closed windows gracefully', function()
        local win, _ = create_diff_window()
        runtime.attach_diff()
        close_window(win)

        assert.has_no.errors(function()
          runtime.detach_diff()
        end)
      end)

      it('clears all tracked windows', function()
        local win1, _ = create_diff_window()
        local win2, _ = create_diff_window()
        runtime.attach_diff()
        runtime.detach_diff()

        local whl1 = vim.api.nvim_get_option_value('winhighlight', { win = win1 })
        local whl2 = vim.api.nvim_get_option_value('winhighlight', { win = win2 })
        assert.are.equal('', whl1)
        assert.are.equal('', whl2)

        close_window(win1)
        close_window(win2)
      end)
    end)
  end)

  describe('compute_highlight_groups', function()
    local saved_get_hl, saved_set_hl, saved_schedule
    local set_calls, schedule_cbs

    before_each(function()
      saved_get_hl = vim.api.nvim_get_hl
      saved_set_hl = vim.api.nvim_set_hl
      saved_schedule = vim.schedule
      set_calls = {}
      schedule_cbs = {}
      vim.api.nvim_set_hl = function(_, group, opts)
        set_calls[group] = opts
      end
      vim.schedule = function(cb)
        table.insert(schedule_cbs, cb)
      end
      runtime._test.set_hl_retry_pending(false)
    end)

    after_each(function()
      vim.api.nvim_get_hl = saved_get_hl
      vim.api.nvim_set_hl = saved_set_hl
      vim.schedule = saved_schedule
      runtime._test.set_hl_retry_pending(false)
    end)

    it('omits DiffsClear.bg when Normal.bg is nil (transparent)', function()
      vim.api.nvim_get_hl = function(ns, opts)
        if opts.name == 'Normal' then
          return { fg = 0xc0c0c0 }
        end
        return saved_get_hl(ns, opts)
      end
      runtime._test.compute_highlight_groups()
      assert.is_nil(set_calls.DiffsClear.bg)
      assert.is_table(set_calls.DiffsAdd)
      assert.is_table(set_calls.DiffsDelete)
    end)

    it('sets DiffsClear.bg to Normal.bg on opaque themes', function()
      vim.api.nvim_get_hl = function(ns, opts)
        if opts.name == 'Normal' then
          return { fg = 0xebdbb2, bg = 0x282828 }
        end
        if opts.name == 'LineNr' then
          return { fg = 0x665c54 }
        end
        if opts.name == 'diffAdded' then
          return { fg = 0x80c080 }
        end
        if opts.name == 'diffRemoved' then
          return { fg = 0xc08080 }
        end
        return saved_get_hl(ns, opts)
      end
      runtime._test.compute_highlight_groups()
      assert.are.equal(0x282828, set_calls.DiffsClear.bg)
      assert.are.equal(0xebdbb2, set_calls.DiffsRail.fg)
      assert.are.equal(0x282828, set_calls.DiffsRail.bg)
      assert.is_true(set_calls.DiffsRail.nocombine)
      assert.are.equal(0x665c54, set_calls.DiffsRailNr.fg)
      assert.are.equal(0x282828, set_calls.DiffsRailNr.bg)
      assert.is_true(set_calls.DiffsRailNr.nocombine)
      assert.are.equal(0x80c080, set_calls.DiffsAddRailNr.fg)
      assert.is_number(set_calls.DiffsAddRailNr.bg)
      assert.is_true(set_calls.DiffsAddRailNr.nocombine)
      assert.are.equal(0xc08080, set_calls.DiffsDeleteRailNr.fg)
      assert.is_number(set_calls.DiffsDeleteRailNr.bg)
      assert.is_true(set_calls.DiffsDeleteRailNr.nocombine)
      assert.are.equal(0x80c080, set_calls.DiffsAddBar.fg)
      assert.is_number(set_calls.DiffsAddBar.bg)
      assert.are.equal(0xc08080, set_calls.DiffsDeleteBar.fg)
      assert.is_number(set_calls.DiffsDeleteBar.bg)
    end)

    it('blend_alpha controls DiffsAdd.bg intensity', function()
      local saved_config_alpha = runtime._test.get_config().highlights.blend_alpha
      runtime._test.get_config().highlights.blend_alpha = 0.3
      vim.api.nvim_get_hl = function(ns, opts)
        if opts.name == 'Normal' then
          return { fg = 0xc0c0c0, bg = 0x1e1e2e }
        end
        if opts.name == 'DiffAdd' then
          return { bg = 0x1a3a1a }
        end
        if opts.name == 'DiffDelete' then
          return { bg = 0x3a1a1a }
        end
        return saved_get_hl(ns, opts)
      end
      runtime._test.compute_highlight_groups()
      local bg_03 = set_calls.DiffsAdd.bg

      runtime._test.get_config().highlights.blend_alpha = 0.9
      runtime._test.compute_highlight_groups()
      local bg_09 = set_calls.DiffsAdd.bg

      assert.is_not.equal(bg_03, bg_09)

      runtime._test.get_config().highlights.blend_alpha = saved_config_alpha
    end)

    it('retries once then stops when Normal.bg stays nil', function()
      vim.api.nvim_get_hl = function(ns, opts)
        if opts.name == 'Normal' then
          return { fg = 0xc0c0c0 }
        end
        return saved_get_hl(ns, opts)
      end
      runtime._test.compute_highlight_groups()
      assert.are.equal(1, #schedule_cbs)
      schedule_cbs[1]()
      assert.are.equal(1, #schedule_cbs)
      assert.is_true(runtime._test.get_hl_retry_pending())
    end)

    it('picks up bg on retry when colorscheme loads late', function()
      local call_count = 0
      vim.api.nvim_get_hl = function(ns, opts)
        if opts.name == 'Normal' then
          call_count = call_count + 1
          if call_count <= 1 then
            return { fg = 0xc0c0c0 }
          end
          return { fg = 0xc0c0c0, bg = 0x1e1e2e }
        end
        return saved_get_hl(ns, opts)
      end
      runtime._test.compute_highlight_groups()
      assert.are.equal(1, #schedule_cbs)
      schedule_cbs[1]()
      assert.are.equal(0x1e1e2e, set_calls.DiffsClear.bg)
      assert.are.equal(1, #schedule_cbs)
    end)
  end)
end)
