local commands = require('diffs.commands')
local helpers = require('spec.helpers')

local counter = 0

local function create_diffs_buffer(name)
  counter = counter + 1
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    'diff --git a/file.lua b/file.lua',
    '--- a/file.lua',
    '+++ b/file.lua',
    '@@ -1,1 +1,2 @@',
    ' local x = 1',
    '+local y = 2',
  })
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = bufnr })
  vim.api.nvim_buf_set_name(bufnr, name or ('diffs://unstaged:file_' .. counter .. '.lua'))
  return bufnr
end

describe('ux', function()
  describe('diagnostics', function()
    it('disables diagnostics on diff buffers', function()
      local bufnr = create_diffs_buffer()
      commands.setup_diff_buf(bufnr)

      assert.is_false(vim.diagnostic.is_enabled({ bufnr = bufnr }))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('does not affect other buffers', function()
      local diff_buf = create_diffs_buffer()
      local normal_buf = helpers.create_buffer({ 'hello' })

      commands.setup_diff_buf(diff_buf)

      assert.is_true(vim.diagnostic.is_enabled({ bufnr = normal_buf }))
      vim.api.nvim_buf_delete(diff_buf, { force = true })
      helpers.delete_buffer(normal_buf)
    end)
  end)

  describe('q keymap', function()
    it('sets q keymap on diff buffer', function()
      local bufnr = create_diffs_buffer()
      commands.setup_diff_buf(bufnr)

      local keymaps = vim.api.nvim_buf_get_keymap(bufnr, 'n')
      local has_q = false
      for _, km in ipairs(keymaps) do
        if km.lhs == 'q' then
          has_q = true
          break
        end
      end
      assert.is_true(has_q)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('q closes the window', function()
      local bufnr = create_diffs_buffer()
      commands.setup_diff_buf(bufnr)

      vim.cmd('split')
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, bufnr)

      local win_count_before = #vim.api.nvim_tabpage_list_wins(0)

      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd('normal q')
      end)

      local win_count_after = #vim.api.nvim_tabpage_list_wins(0)
      assert.equals(win_count_before - 1, win_count_after)
    end)
  end)

  describe('window reuse', function()
    it('returns nil when no diffs window exists', function()
      local win = commands.find_diffs_window()
      assert.is_nil(win)
    end)

    it('finds existing diffs:// window', function()
      local bufnr = create_diffs_buffer()
      vim.cmd('split')
      local expected_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(expected_win, bufnr)

      local found = commands.find_diffs_window()
      assert.equals(expected_win, found)

      vim.api.nvim_win_close(expected_win, true)
    end)

    it('ignores non-diffs buffers', function()
      local normal_buf = helpers.create_buffer({ 'hello' })
      vim.cmd('split')
      local win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win, normal_buf)

      local found = commands.find_diffs_window()
      assert.is_nil(found)

      vim.api.nvim_win_close(win, true)
      helpers.delete_buffer(normal_buf)
    end)

    it('returns first diffs window when multiple exist', function()
      local buf1 = create_diffs_buffer()
      local buf2 = create_diffs_buffer()

      vim.cmd('split')
      local win1 = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win1, buf1)

      vim.cmd('split')
      local win2 = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(win2, buf2)

      local found = commands.find_diffs_window()
      assert.is_not_nil(found)
      assert.is_true(found == win1 or found == win2)

      vim.api.nvim_win_close(win1, true)
      vim.api.nvim_win_close(win2, true)
    end)
  end)
end)
