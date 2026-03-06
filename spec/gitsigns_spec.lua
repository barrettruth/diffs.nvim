require('spec.helpers')
local gs = require('diffs.gitsigns')

local function setup_highlight_groups()
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
  local diff_add = vim.api.nvim_get_hl(0, { name = 'DiffAdd' })
  local diff_delete = vim.api.nvim_get_hl(0, { name = 'DiffDelete' })
  vim.api.nvim_set_hl(0, 'DiffsClear', { fg = normal.fg or 0xc0c0c0 })
  vim.api.nvim_set_hl(0, 'DiffsAdd', { bg = diff_add.bg or 0x2e4a3a })
  vim.api.nvim_set_hl(0, 'DiffsDelete', { bg = diff_delete.bg or 0x4a2e3a })
  vim.api.nvim_set_hl(0, 'DiffsAddText', { bg = 0x00FF00 })
  vim.api.nvim_set_hl(0, 'DiffsDeleteText', { bg = 0xFF0000 })
end

local function create_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  return bufnr
end

local function delete_buffer(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

describe('gitsigns', function()
  describe('parse_blame_hunks', function()
    it('parses a single hunk', function()
      local bufnr = create_buffer({
        'commit abc1234',
        'Author: Test User',
        '',
        'Hunk 1 of 1',
        ' local x = 1',
        '-local y = 2',
        '+local y = 3',
        ' local z = 4',
      })
      local hunks = gs.parse_blame_hunks(bufnr, 'test.lua', 'lua', 'lua')
      assert.are.equal(1, #hunks)
      assert.are.equal('test.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].ft)
      assert.are.equal('lua', hunks[1].lang)
      assert.are.equal(1, hunks[1].prefix_width)
      assert.are.equal(0, hunks[1].quote_width)
      assert.are.equal(4, #hunks[1].lines)
      assert.are.equal(4, hunks[1].start_line)
      assert.are.equal(' local x = 1', hunks[1].lines[1])
      assert.are.equal('-local y = 2', hunks[1].lines[2])
      assert.are.equal('+local y = 3', hunks[1].lines[3])
      delete_buffer(bufnr)
    end)

    it('parses multiple hunks', function()
      local bufnr = create_buffer({
        'commit abc1234',
        '',
        'Hunk 1 of 2',
        '-local a = 1',
        '+local a = 2',
        'Hunk 2 of 2',
        ' local b = 3',
        '+local c = 4',
      })
      local hunks = gs.parse_blame_hunks(bufnr, 'test.lua', 'lua', 'lua')
      assert.are.equal(2, #hunks)
      assert.are.equal(2, #hunks[1].lines)
      assert.are.equal(2, #hunks[2].lines)
      delete_buffer(bufnr)
    end)

    it('skips guessed-offset lines', function()
      local bufnr = create_buffer({
        'commit abc1234',
        '',
        'Hunk 1 of 1',
        '(guessed: hunk offset may be wrong)',
        ' local x = 1',
        '+local y = 2',
      })
      local hunks = gs.parse_blame_hunks(bufnr, 'test.lua', 'lua', 'lua')
      assert.are.equal(1, #hunks)
      assert.are.equal(2, #hunks[1].lines)
      assert.are.equal(' local x = 1', hunks[1].lines[1])
      delete_buffer(bufnr)
    end)

    it('returns empty table when no hunks present', function()
      local bufnr = create_buffer({
        'commit abc1234',
        'Author: Test User',
        'Date: 2024-01-01',
      })
      local hunks = gs.parse_blame_hunks(bufnr, 'test.lua', 'lua', 'lua')
      assert.are.equal(0, #hunks)
      delete_buffer(bufnr)
    end)

    it('handles hunk with no diff lines after header', function()
      local bufnr = create_buffer({
        'Hunk 1 of 1',
        'some non-diff text',
      })
      local hunks = gs.parse_blame_hunks(bufnr, 'test.lua', 'lua', 'lua')
      assert.are.equal(0, #hunks)
      delete_buffer(bufnr)
    end)
  end)

  describe('on_preview', function()
    before_each(function()
      setup_highlight_groups()
    end)

    it('applies extmarks to popup buffer with diff content', function()
      local bufnr = create_buffer({
        'commit abc1234',
        '',
        'Hunk 1 of 1',
        ' local x = 1',
        '-local y = 2',
        '+local y = 3',
      })

      local winid = vim.api.nvim_open_win(bufnr, false, {
        relative = 'editor',
        width = 40,
        height = 10,
        row = 0,
        col = 0,
      })

      gs._test.on_preview(winid, bufnr)

      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, gs._test.ns, 0, -1, { details = true })
      assert.is_true(#extmarks > 0)

      vim.api.nvim_win_close(winid, true)
      delete_buffer(bufnr)
    end)

    it('clears gitsigns_popup namespace on diff region', function()
      local bufnr = create_buffer({
        'commit abc1234',
        '',
        'Hunk 1 of 1',
        ' local x = 1',
        '+local y = 2',
      })

      vim.api.nvim_buf_set_extmark(bufnr, gs._test.gs_popup_ns, 3, 0, {
        end_col = 12,
        hl_group = 'GitSignsAddPreview',
      })
      vim.api.nvim_buf_set_extmark(bufnr, gs._test.gs_popup_ns, 4, 0, {
        end_col = 12,
        hl_group = 'GitSignsAddPreview',
      })

      local winid = vim.api.nvim_open_win(bufnr, false, {
        relative = 'editor',
        width = 40,
        height = 10,
        row = 0,
        col = 0,
      })

      gs._test.on_preview(winid, bufnr)

      local gs_extmarks =
        vim.api.nvim_buf_get_extmarks(bufnr, gs._test.gs_popup_ns, 0, -1, { details = true })
      assert.are.equal(0, #gs_extmarks)

      vim.api.nvim_win_close(winid, true)
      delete_buffer(bufnr)
    end)

    it('does not error on invalid buffer', function()
      assert.has_no.errors(function()
        gs._test.on_preview(0, 99999)
      end)
    end)
  end)

  describe('setup', function()
    it('returns false when gitsigns.popup is not available', function()
      local saved = package.loaded['gitsigns.popup']
      package.loaded['gitsigns.popup'] = nil
      package.preload['gitsigns.popup'] = nil

      local fresh = loadfile('lua/diffs/gitsigns.lua')()
      local result = fresh.setup()
      assert.is_false(result)

      package.loaded['gitsigns.popup'] = saved
    end)

    it('patches gitsigns.popup when available', function()
      local create_called = false
      local update_called = false
      local mock_popup = {
        create = function()
          create_called = true
          local bufnr = create_buffer({ 'test' })
          local winid = vim.api.nvim_open_win(bufnr, false, {
            relative = 'editor',
            width = 10,
            height = 1,
            row = 0,
            col = 0,
          })
          return winid, bufnr
        end,
        update = function()
          update_called = true
        end,
      }

      local saved = package.loaded['gitsigns.popup']
      package.loaded['gitsigns.popup'] = mock_popup

      local fresh = loadfile('lua/diffs/gitsigns.lua')()
      local result = fresh.setup()
      assert.is_true(result)

      mock_popup.create()
      assert.is_true(create_called)

      mock_popup.update(0, 0)
      assert.is_true(update_called)

      package.loaded['gitsigns.popup'] = saved
    end)
  end)
end)
