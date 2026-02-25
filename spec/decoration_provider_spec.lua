require('spec.helpers')
local diffs = require('diffs')

describe('decoration_provider', function()
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

  describe('ensure_cache', function()
    it('populates hunk cache for a buffer with diff content', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        '-local y = 2',
        '+local y = 3',
        ' local z = 4',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.is_table(entry.hunks)
      assert.is_true(#entry.hunks > 0)
      delete_buffer(bufnr)
    end)

    it('cache tick matches buffer changedtick after attach', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)
      assert.are.equal(tick, entry.tick)
      delete_buffer(bufnr)
    end)

    it('re-parses and advances tick when buffer content changes', function()
      local bufnr = create_buffer({
        'M test.lua',
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

    it('skips reparse when fingerprint unchanged but sets pending_clear', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      local original_hunks = entry.hunks
      entry.pending_clear = false

      local lc = vim.api.nvim_buf_line_count(bufnr)
      local bc = vim.api.nvim_buf_get_offset(bufnr, lc)
      entry.line_count = lc
      entry.byte_count = bc
      entry.tick = -1

      diffs._test.ensure_cache(bufnr)

      local updated = diffs._test.hunk_cache[bufnr]
      local current_tick = vim.api.nvim_buf_get_changedtick(bufnr)
      assert.are.equal(original_hunks, updated.hunks)
      assert.are.equal(current_tick, updated.tick)
      assert.is_true(updated.pending_clear)
      delete_buffer(bufnr)
    end)

    it('does nothing for invalid buffer', function()
      local bufnr = create_buffer({})
      diffs.attach(bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.has_no.errors(function()
        diffs._test.ensure_cache(bufnr)
      end)
    end)
  end)

  describe('pending_clear', function()
    it('is true after invalidate_cache', function()
      local bufnr = create_buffer({})
      diffs.attach(bufnr)
      diffs._test.invalidate_cache(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_true(entry.pending_clear)
      delete_buffer(bufnr)
    end)

    it('is true immediately after fresh ensure_cache', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_true(entry.pending_clear)
      delete_buffer(bufnr)
    end)
  end)

  describe('BufWipeout cleanup', function()
    it('removes hunk_cache entry after buffer wipeout', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)
      assert.is_not_nil(diffs._test.hunk_cache[bufnr])
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(diffs._test.hunk_cache[bufnr])
    end)
  end)

  describe('multiple hunks in cache', function()
    it('stores all parsed hunks for a multi-hunk buffer', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,2 +1,2 @@',
        ' local x = 1',
        '-local y = 2',
        '+local y = 3',
        '@@ -10,2 +10,3 @@',
        ' function M.foo()',
        '+  return true',
        ' end',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.are.equal(2, #entry.hunks)
      delete_buffer(bufnr)
    end)

    it('stores empty hunks table for buffer with no diff content', function()
      local bufnr = create_buffer({
        'Head: main',
        'Help: g?',
        '',
        'Nothing to see here',
      })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.are.same({}, entry.hunks)
      delete_buffer(bufnr)
    end)
  end)
end)
