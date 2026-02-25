require('spec.helpers')
local diffs = require('diffs')
local highlight = require('diffs.highlight')

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
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

local function get_diffs_ns()
  return vim.api.nvim_get_namespaces()['diffs']
end

local function get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

local function highlight_opts_with_background()
  return {
    hide_prefix = false,
    highlights = {
      background = true,
      gutter = false,
      context = { enabled = false, lines = 0 },
      treesitter = { enabled = true, max_lines = 500 },
      vim = { enabled = false, max_lines = 200 },
      intra = { enabled = false, algorithm = 'default', max_lines = 500 },
      priorities = { clear = 198, syntax = 199, line_bg = 200, char_bg = 201 },
    },
  }
end

describe('integration', function()
  before_each(function()
    setup_highlight_groups()
  end)

  describe('attach and parse', function()
    it('attach populates hunk cache for unified diff buffer', function()
      local bufnr = create_buffer({
        'diff --git a/foo.lua b/foo.lua',
        'index abc..def 100644',
        '--- a/foo.lua',
        '+++ b/foo.lua',
        '@@ -1,3 +1,3 @@',
        ' local x = 1',
        '-local y = 2',
        '+local y = 3',
        ' local z = 4',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.are.equal(1, #entry.hunks)
      assert.are.equal('foo.lua', entry.hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('attach parses multiple hunks across multiple files', function()
      local bufnr = create_buffer({
        'M foo.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
        'M bar.lua',
        '@@ -1,1 +1,2 @@',
        ' local a = 1',
        '+local b = 2',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.are.equal(2, #entry.hunks)
      delete_buffer(bufnr)
    end)

    it('re-attach on same buffer is idempotent', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local entry_before = diffs._test.hunk_cache[bufnr]
      local tick_before = entry_before.tick
      diffs.attach(bufnr)
      local entry_after = diffs._test.hunk_cache[bufnr]
      assert.are.equal(tick_before, entry_after.tick)
      delete_buffer(bufnr)
    end)

    it('refresh after content change invalidates cache', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local tick_before = diffs._test.hunk_cache[bufnr].tick
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '+local z = 3' })
      diffs.refresh(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.are.equal(-1, entry.tick)
      assert.is_true(entry.pending_clear)
      assert.is_true(tick_before >= 0)
      delete_buffer(bufnr)
    end)
  end)

  describe('extmarks from highlight pipeline', function()
    it('DiffsAdd background applied to + lines', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      local ns = vim.api.nvim_create_namespace('diffs_integration_test_add')
      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
      }
      highlight.highlight_hunk(bufnr, ns, hunk, highlight_opts_with_background())
      local extmarks = get_extmarks(bufnr, ns)
      local has_diff_add = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsAdd' then
          has_diff_add = true
          break
        end
      end
      assert.is_true(has_diff_add)
      delete_buffer(bufnr)
    end)

    it('DiffsDelete background applied to - lines', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,1 @@',
        ' local x = 1',
        '-local y = 2',
      })
      local ns = vim.api.nvim_create_namespace('diffs_integration_test_del')
      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '-local y = 2' },
      }
      highlight.highlight_hunk(bufnr, ns, hunk, highlight_opts_with_background())
      local extmarks = get_extmarks(bufnr, ns)
      local has_diff_delete = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsDelete' then
          has_diff_delete = true
          break
        end
      end
      assert.is_true(has_diff_delete)
      delete_buffer(bufnr)
    end)

    it('mixed hunk produces both DiffsAdd and DiffsDelete backgrounds', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,2 @@',
        '-local x = 1',
        '+local x = 2',
      })
      local ns = vim.api.nvim_create_namespace('diffs_integration_test_mixed')
      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '-local x = 1', '+local x = 2' },
      }
      highlight.highlight_hunk(bufnr, ns, hunk, highlight_opts_with_background())
      local extmarks = get_extmarks(bufnr, ns)
      local has_add = false
      local has_delete = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsAdd' then
          has_add = true
        end
        if mark[4] and mark[4].hl_group == 'DiffsDelete' then
          has_delete = true
        end
      end
      assert.is_true(has_add)
      assert.is_true(has_delete)
      delete_buffer(bufnr)
    end)

    it('no background extmarks for context lines', function()
      local bufnr = create_buffer({
        '@@ -1,3 +1,3 @@',
        ' local x = 1',
        '-local y = 2',
        '+local y = 3',
        ' local z = 4',
      })
      local ns = vim.api.nvim_create_namespace('diffs_integration_test_ctx')
      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '-local y = 2', '+local y = 3', ' local z = 4' },
      }
      highlight.highlight_hunk(bufnr, ns, hunk, highlight_opts_with_background())
      local extmarks = get_extmarks(bufnr, ns)
      local line_bgs = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') and d.hl_eol then
          line_bgs[mark[2]] = d.hl_group
        end
      end
      assert.is_nil(line_bgs[1])
      assert.is_nil(line_bgs[4])
      assert.are.equal('DiffsDelete', line_bgs[2])
      assert.are.equal('DiffsAdd', line_bgs[3])
      delete_buffer(bufnr)
    end)

    it('treesitter extmarks applied for lua hunks', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        '+local y = 2',
        ' return x',
      })
      local ns = vim.api.nvim_create_namespace('diffs_integration_test_ts')
      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2', ' return x' },
      }
      highlight.highlight_hunk(bufnr, ns, hunk, highlight_opts_with_background())
      local extmarks = get_extmarks(bufnr, ns)
      local has_ts = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group:match('^@.*%.lua$') then
          has_ts = true
          break
        end
      end
      assert.is_true(has_ts)
      delete_buffer(bufnr)
    end)

    it('diffs namespace exists after attach', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local ns = get_diffs_ns()
      assert.is_not_nil(ns)
      assert.is_number(ns)
      delete_buffer(bufnr)
    end)
  end)

  describe('multiple hunks highlighting', function()
    it('both hunks in multi-hunk buffer get background extmarks', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,2 @@',
        '-local x = 1',
        '+local x = 10',
        '@@ -10,2 +10,2 @@',
        '-local y = 2',
        '+local y = 20',
      })
      local ns = vim.api.nvim_create_namespace('diffs_integration_test_multi')
      local hunk1 = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '-local x = 1', '+local x = 10' },
      }
      local hunk2 = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 4,
        lines = { '-local y = 2', '+local y = 20' },
      }
      highlight.highlight_hunk(bufnr, ns, hunk1, highlight_opts_with_background())
      highlight.highlight_hunk(bufnr, ns, hunk2, highlight_opts_with_background())
      local extmarks = get_extmarks(bufnr, ns)
      local add_lines = {}
      local del_lines = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsAdd' and d.hl_eol then
          add_lines[mark[2]] = true
        end
        if d and d.hl_group == 'DiffsDelete' and d.hl_eol then
          del_lines[mark[2]] = true
        end
      end
      assert.is_true(del_lines[1] ~= nil)
      assert.is_true(add_lines[2] ~= nil)
      assert.is_true(del_lines[4] ~= nil)
      assert.is_true(add_lines[5] ~= nil)
      delete_buffer(bufnr)
    end)
  end)
end)
