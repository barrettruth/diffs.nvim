local helpers = require('spec.helpers')

local commands = require('diffs.commands')
local diffspec = require('diffs.spec')
local hunks = require('diffs.hunks')

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

local function add_hunk_metadata(bufnr, diff_spec)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.api.nvim_buf_set_var(
    bufnr,
    'diffs_hunks',
    hunks.parse(lines, diff_spec or diffspec.index_to_worktree('file.lua'))
  )
  vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', '/tmp/repo')
end

local function keymap_desc(bufnr, lhs, mode)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode or 'n')) do
    if keymap.lhs == lhs then
      return keymap.desc
    end
  end
  return nil
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

    it('does not replace an existing q keymap', function()
      local bufnr = create_diffs_buffer()
      vim.keymap.set('n', 'q', '<Nop>', { buffer = bufnr, desc = 'user q' })

      commands.setup_diff_buf(bufnr)

      assert.are.equal('user q', keymap_desc(bufnr, 'q'))
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

  describe('hunk keymaps', function()
    it('sets hunk keymaps only on hunk-aware diff buffers', function()
      local bufnr = create_diffs_buffer()
      commands.setup_diff_buf(bufnr)

      assert.is_false(helpers.has_keymap(bufnr, ']c'))
      assert.is_false(helpers.has_keymap(bufnr, '[c'))
      assert.is_false(helpers.has_keymap(bufnr, '<CR>'))
      assert.is_false(helpers.has_keymap(bufnr, 'o'))
      assert.is_false(helpers.has_keymap(bufnr, 'do'))
      assert.is_false(helpers.has_keymap(bufnr, 'dp'))
      assert.is_false(helpers.has_keymap(bufnr, 'do', 'x'))
      assert.is_false(helpers.has_keymap(bufnr, 'dp', 'x'))

      add_hunk_metadata(bufnr)
      commands.setup_diff_buf(bufnr)

      assert.is_true(helpers.has_keymap(bufnr, ']c'))
      assert.is_true(helpers.has_keymap(bufnr, '[c'))
      assert.is_true(helpers.has_keymap(bufnr, '<CR>'))
      assert.is_false(helpers.has_keymap(bufnr, 'o'))
      assert.is_false(helpers.has_keymap(bufnr, 'do'))
      assert.is_true(helpers.has_keymap(bufnr, 'dp'))
      assert.is_false(helpers.has_keymap(bufnr, 'do', 'x'))
      assert.is_true(helpers.has_keymap(bufnr, 'dp', 'x'))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('does not replace existing buffer-local hunk maps', function()
      local bufnr = create_diffs_buffer()
      add_hunk_metadata(bufnr)
      vim.keymap.set('n', 'o', '<Nop>', { buffer = bufnr, desc = 'user open' })
      vim.keymap.set('n', ']c', '<Nop>', { buffer = bufnr, desc = 'user next' })
      vim.keymap.set('n', 'do', '<Nop>', { buffer = bufnr, desc = 'user obtain' })
      vim.keymap.set('n', 'dp', '<Nop>', { buffer = bufnr, desc = 'user put' })
      vim.keymap.set('x', 'do', '<Nop>', { buffer = bufnr, desc = 'user visual obtain' })
      vim.keymap.set('x', 'dp', '<Nop>', { buffer = bufnr, desc = 'user visual put' })

      commands.setup_diff_buf(bufnr)

      assert.are.equal('user open', keymap_desc(bufnr, 'o'))
      assert.are.equal('user next', keymap_desc(bufnr, ']c'))
      assert.are.equal('user obtain', keymap_desc(bufnr, 'do'))
      assert.are.equal('user put', keymap_desc(bufnr, 'dp'))
      assert.are.equal('user visual obtain', keymap_desc(bufnr, 'do', 'x'))
      assert.are.equal('user visual put', keymap_desc(bufnr, 'dp', 'x'))
      assert.are.equal('Open source file', keymap_desc(bufnr, '<CR>'))
      assert.are.equal('Previous diff hunk', keymap_desc(bufnr, '[c'))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('removes only plugin-owned hunk keymaps when metadata is removed', function()
      local bufnr = create_diffs_buffer()
      add_hunk_metadata(bufnr)
      vim.keymap.set('n', 'o', '<Nop>', { buffer = bufnr, desc = 'user open' })
      vim.keymap.set('x', 'do', '<Nop>', { buffer = bufnr, desc = 'user visual obtain' })
      commands.setup_diff_buf(bufnr)

      assert.are.equal('user open', keymap_desc(bufnr, 'o'))
      assert.are.equal('user visual obtain', keymap_desc(bufnr, 'do', 'x'))
      assert.are.equal('Open source file', keymap_desc(bufnr, '<CR>'))
      assert.are.equal('Stage selected Gdiff lines', keymap_desc(bufnr, 'dp', 'x'))

      vim.api.nvim_buf_del_var(bufnr, 'diffs_hunks')
      commands.setup_diff_buf(bufnr)

      assert.are.equal('user open', keymap_desc(bufnr, 'o'))
      assert.are.equal('user visual obtain', keymap_desc(bufnr, 'do', 'x'))
      assert.is_nil(keymap_desc(bufnr, '<CR>'))
      assert.is_nil(keymap_desc(bufnr, ']c'))
      assert.is_nil(keymap_desc(bufnr, '[c'))
      assert.is_nil(keymap_desc(bufnr, 'do'))
      assert.is_nil(keymap_desc(bufnr, 'dp'))
      assert.is_nil(keymap_desc(bufnr, 'dp', 'x'))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('updates plugin-owned action keymaps when hunk actionability changes', function()
      local bufnr = create_diffs_buffer()
      add_hunk_metadata(bufnr, diffspec.index_to_worktree('file.lua'))
      commands.setup_diff_buf(bufnr)

      assert.is_true(helpers.has_keymap(bufnr, 'dp'))
      assert.is_false(helpers.has_keymap(bufnr, 'do'))

      add_hunk_metadata(bufnr, diffspec.head_to_index('file.lua'))
      commands.setup_diff_buf(bufnr)

      assert.is_false(helpers.has_keymap(bufnr, 'dp'))
      assert.is_false(helpers.has_keymap(bufnr, 'dp', 'x'))
      assert.is_true(helpers.has_keymap(bufnr, 'do'))
      assert.is_true(helpers.has_keymap(bufnr, 'do', 'x'))
      assert.is_true(helpers.has_keymap(bufnr, ']c'))
      assert.is_true(helpers.has_keymap(bufnr, '[c'))
      assert.is_true(helpers.has_keymap(bufnr, '<CR>'))
      assert.is_false(helpers.has_keymap(bufnr, 'o'))
      vim.api.nvim_buf_delete(bufnr, { force = true })
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
