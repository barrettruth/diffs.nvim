require('spec.helpers')
local runtime = require('diffs.runtime')

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
    it('reparses same-size edits and clears stale highlights', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,4 +1,5 @@',
        ' local x = 1',
        '+local y = 2',
        ' local z = 3',
        ' local w = 4',
        ' return x',
      })
      runtime.attach(bufnr)
      runtime._test.process_pending_clear(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      entry.highlighted = { [1] = true }
      local ns = vim.api.nvim_create_namespace('diffs')
      vim.api.nvim_buf_set_extmark(bufnr, ns, 3, 0, { hl_group = 'DiffsAdd', end_col = 12 })

      vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { '+local y = 9' })
      runtime._test.ensure_cache(bufnr)

      local updated = runtime._test.hunk_cache[bufnr]
      assert.are.equal('+local y = 9', updated.hunks[1].lines[2])
      assert.are.same({}, updated.highlighted)
      runtime._test.process_pending_clear(bufnr)
      assert.are.same({}, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
      delete_buffer(bufnr)
    end)

    it('does nothing for invalid buffer', function()
      local bufnr = create_buffer({})
      runtime.attach(bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.has_no.errors(function()
        runtime._test.ensure_cache(bufnr)
      end)
    end)
  end)

  describe('pending_clear', function()
    it('clears namespace extmarks when on_buf processes pending_clear', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      runtime.attach(bufnr)
      local ns_id = vim.api.nvim_create_namespace('diffs')
      vim.api.nvim_buf_set_extmark(bufnr, ns_id, 0, 0, { line_hl_group = 'DiffAdd' })
      assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {}))

      runtime._test.invalidate_cache(bufnr)
      runtime._test.ensure_cache(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.is_true(entry.pending_clear)

      runtime._test.process_pending_clear(bufnr)

      entry = runtime._test.hunk_cache[bufnr]
      assert.is_false(entry.pending_clear)
      assert.are.same({}, vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, {}))
      delete_buffer(bufnr)
    end)
  end)

  describe('deferred vim syntax', function()
    it('skips stale deferred vim syntax when changedtick advanced', function()
      local orig_synID = vim.fn.synID
      local orig_synIDtrans = vim.fn.synIDtrans
      local orig_synIDattr = vim.fn.synIDattr
      vim.fn.synID = function(_line, _col, _trans)
        return 1
      end
      vim.fn.synIDtrans = function(id)
        return id
      end
      vim.fn.synIDattr = function(_id, _what)
        return 'Identifier'
      end

      local bufnr = create_buffer({
        'M video.txt',
        '@@ -1,1 +1,2 @@',
        ' alpha',
        '+beta',
      })
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
      local job_id = runtime._test.next_syntax_job(bufnr)

      vim.api.nvim_buf_set_lines(bufnr, 1, 4, false, {
        '@@ -1,1 +1,1 @@',
        ' gamma',
      })

      local ok = runtime._test.run_deferred_syntax(
        bufnr,
        entry.tick,
        changedtick,
        job_id,
        { entry.hunks[1] }
      )
      local ns_id = vim.api.nvim_create_namespace('diffs')
      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })

      vim.fn.synID = orig_synID
      vim.fn.synIDtrans = orig_synIDtrans
      vim.fn.synIDattr = orig_synIDattr

      assert.is_false(ok)
      assert.are.equal(0, #extmarks)
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
      runtime.attach(bufnr)
      assert.is_not_nil(runtime._test.hunk_cache[bufnr])
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(runtime._test.hunk_cache[bufnr])
    end)
  end)

  describe('hunk stability', function()
    it('forces full clear on section expansion (hunk count changed)', function()
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
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.are.equal(2, #entry.hunks)

      entry.pending_clear = false
      entry.highlighted = { [1] = true, [2] = true }

      vim.api.nvim_buf_set_lines(bufnr, 5, 5, false, {
        '@@ -5,1 +5,2 @@',
        ' local z = 4',
        '+local w = 5',
      })
      runtime._test.ensure_cache(bufnr)

      local updated = runtime._test.hunk_cache[bufnr]
      assert.are.equal(3, #updated.hunks)
      assert.are.same({}, updated.highlighted)
      assert.is_true(updated.pending_clear)
      delete_buffer(bufnr)
    end)

    it('forces full clear on section collapse (stale extmarks from removed hunks)', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,2 +1,2 @@',
        ' local x = 1',
        '-local y = 2',
        '+local y = 3',
        '@@ -5,1 +5,2 @@',
        ' local z = 4',
        '+local w = 5',
        '@@ -10,2 +10,3 @@',
        ' function M.foo()',
        '+  return true',
        ' end',
      })
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.are.equal(3, #entry.hunks)

      entry.pending_clear = false
      entry.highlighted = { [1] = true, [2] = true, [3] = true }

      vim.api.nvim_buf_set_lines(bufnr, 5, 8, false, {})
      runtime._test.ensure_cache(bufnr)

      local updated = runtime._test.hunk_cache[bufnr]
      assert.are.equal(2, #updated.hunks)
      assert.are.same({}, updated.highlighted)
      assert.is_true(updated.pending_clear)
      delete_buffer(bufnr)
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
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
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
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.are.same({}, entry.hunks)
      delete_buffer(bufnr)
    end)
  end)
end)
