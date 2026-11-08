require('spec.helpers')
local highlight = require('diffs.highlight')
local runtime = require('diffs.runtime')

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

local function get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

local function highlight_opts_with_background()
  return {
    hide_prefix = false,
    highlights = {
      background = true,
      treesitter = { max_lines = 500 },
      vim = false,
      intra = false,
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
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
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
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
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
      runtime.attach(bufnr)
      local entry_before = runtime._test.hunk_cache[bufnr]
      local tick_before = entry_before.tick
      runtime.attach(bufnr)
      local entry_after = runtime._test.hunk_cache[bufnr]
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
      runtime.attach(bufnr)
      local tick_before = runtime._test.hunk_cache[bufnr].tick
      vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { '+local z = 3' })
      runtime.refresh(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.are.equal(-1, entry.tick)
      assert.is_true(entry.pending_clear)
      assert.is_true(tick_before >= 0)
      delete_buffer(bufnr)
    end)
  end)

  describe('ft_retry_pending', function()
    local saved_schedule
    local scheduled_callbacks

    local function run_scheduled_callbacks()
      local callbacks = scheduled_callbacks
      scheduled_callbacks = {}
      for _, callback in ipairs(callbacks) do
        callback()
      end
    end

    before_each(function()
      rawset(vim.fn, 'did_filetype', function()
        return 1
      end)
      saved_schedule = vim.schedule
      scheduled_callbacks = {}
      vim.schedule = function(callback)
        scheduled_callbacks[#scheduled_callbacks + 1] = callback
      end
      require('diffs.parser')._test.ft_lang_cache = {}
    end)

    after_each(function()
      rawset(vim.fn, 'did_filetype', nil)
      vim.schedule = saved_schedule
      saved_schedule = nil
      scheduled_callbacks = nil
    end)

    it('sets ft_retry_pending when nil-ft hunks detected under did_filetype', function()
      local bufnr = create_buffer({
        'diff --git a/app.conf b/app.conf',
        '@@ -1,2 +1,2 @@',
        ' server {',
        '-    listen 80;',
        '+    listen 8080;',
      })
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.is_nil(entry.hunks[1].ft)
      assert.is_truthy(runtime._test.ft_retry_pending[bufnr])
      delete_buffer(bufnr)
    end)

    it('clears ft_retry_pending after scheduled callback fires', function()
      local bufnr = create_buffer({
        'diff --git a/app.conf b/app.conf',
        '@@ -1,2 +1,2 @@',
        ' server {',
        '-    listen 80;',
        '+    listen 8080;',
      })
      runtime.attach(bufnr)
      assert.is_truthy(runtime._test.ft_retry_pending[bufnr])

      run_scheduled_callbacks()

      assert.is_nil(runtime._test.ft_retry_pending[bufnr])
      delete_buffer(bufnr)
    end)

    it('refreshes cache after scheduled callback fires', function()
      local bufnr = create_buffer({
        'diff --git a/app.conf b/app.conf',
        '@@ -1,2 +1,2 @@',
        ' server {',
        '-    listen 80;',
        '+    listen 8080;',
        'diff --git a/test.lua b/test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      runtime.attach(bufnr)
      local ns = vim.api.nvim_create_namespace('diffs')
      vim.api.nvim_buf_set_extmark(bufnr, ns, 2, 0, {
        end_row = 3,
        end_col = 0,
        hl_group = 'DiffsAdd',
        hl_eol = true,
      })
      local entry = runtime._test.hunk_cache[bufnr]
      entry.highlighted = { [1] = true, [2] = true }
      entry.pending_clear = false

      run_scheduled_callbacks()

      entry = runtime._test.hunk_cache[bufnr]
      assert.are.equal(vim.api.nvim_buf_get_changedtick(bufnr), entry.tick)
      assert.is_false(entry.pending_clear)
      assert.are.same({}, entry.highlighted)
      assert.are.same({}, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
      delete_buffer(bufnr)
    end)

    it('does not set ft_retry_pending when did_filetype() is zero', function()
      rawset(vim.fn, 'did_filetype', nil)
      local bufnr = create_buffer({
        'diff --git a/test.sh b/test.sh',
        '@@ -1,2 +1,3 @@',
        ' #!/usr/bin/env bash',
        '-old line',
        '+new line',
      })
      runtime.attach(bufnr)
      assert.is_falsy(runtime._test.ft_retry_pending[bufnr])
      delete_buffer(bufnr)
    end)

    it('does not set ft_retry_pending for files with resolvable ft', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      runtime.attach(bufnr)
      assert.is_falsy(runtime._test.ft_retry_pending[bufnr])
      delete_buffer(bufnr)
    end)
  end)

  describe('extmarks from highlight pipeline', function()
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
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') then
          line_bgs[mark[2]] = d.hl_group
        end
      end
      assert.is_nil(line_bgs[1])
      assert.is_nil(line_bgs[4])
      assert.are.equal('DiffsDelete', line_bgs[2])
      assert.are.equal('DiffsAdd', line_bgs[3])
      delete_buffer(bufnr)
    end)
  end)
end)
