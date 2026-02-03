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
        debounce_ms = 100,
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
        debounce_ms = 25,
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
