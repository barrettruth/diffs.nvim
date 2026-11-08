require('spec.helpers')
local api = require('diffs')
local helpers = require('spec.helpers')
local highlight = require('diffs.highlight')
local runtime = require('diffs.runtime')

describe('highlighting API', function()
  local bufnr
  local ns = vim.api.nvim_create_namespace('diffs')

  after_each(function()
    helpers.delete_buffer(bufnr)
  end)

  it('replaces the parser and refreshes supplied hunks without a text edit', function()
    bufnr = helpers.create_buffer({ 'row -local value = 1', 'row +local value = 2' })
    vim.api.nvim_set_current_buf(bufnr)
    api.attach(0)
    local supplied = {
      {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 0,
        lines = { '-local value = 1', '+local value = 2' },
        prefix_width = 1,
        quote_width = 0,
        column_offset = 4,
      },
    }
    local calls = 0
    api.attach(0, {
      hunks = function(buffer)
        assert.are.equal(bufnr, buffer)
        calls = calls + 1
        return supplied
      end,
    })
    assert.are.equal(1, calls)
    local entry = runtime._test.hunk_cache[bufnr]
    highlight.highlight_hunk(bufnr, ns, entry.hunks[1], api.highlight_options())
    local marks = helpers.get_extmarks(bufnr, ns)
    assert.is_true(#marks > 0)
    for _, mark in ipairs(marks) do
      assert.is_true(mark[3] >= 4)
    end
    assert.is_nil(supplied[1]._hl_line_count)

    supplied = {}
    api.refresh(0)
    runtime._test.ensure_cache(bufnr)
    runtime._test.process_pending_clear(bufnr)
    assert.are.equal(2, calls)
    assert.are.same({}, runtime._test.hunk_cache[bufnr].hunks)
    assert.are.same({}, helpers.get_extmarks(bufnr, ns))
  end)

  it('keeps no-newline marker rows outside changed text spans', function()
    bufnr = helpers.create_buffer({
      'M test.lua',
      '@@ -1 +1 @@',
      '-local value = 1',
      '\\ No newline at end of file',
      '+local value = 2',
      '\\ No newline at end of file',
    })
    api.attach(bufnr)
    local hunk = runtime._test.hunk_cache[bufnr].hunks[1]
    assert.are.equal(4, #hunk.lines)
    local spans = api.compute_intra_hunks(hunk.lines)
    assert.are.equal(1, spans.del_spans[1].line)
    assert.are.equal(3, spans.add_spans[1].line)
    local options = api.highlight_options()
    options.hide_prefix = true
    highlight.highlight_hunk(bufnr, ns, hunk, options)
    for _, mark in ipairs(helpers.get_extmarks(bufnr, ns)) do
      assert.is_not_equal(3, mark[2])
      assert.is_not_equal(5, mark[2])
    end
  end)

  it('rejects deferred syntax from a detached attachment after reattachment', function()
    bufnr = helpers.create_buffer({
      'M test.lua',
      '@@ -1 +1 @@',
      '-local value = 1',
      '+local value = 2',
    })
    api.attach(bufnr)
    local entry = runtime._test.hunk_cache[bufnr]
    local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    local old_job = runtime._test.next_syntax_job(bufnr)
    vim.api.nvim_buf_set_extmark(bufnr, ns, 2, 1, { end_col = 6, hl_group = 'DiffsDelete' })
    api.detach(bufnr)
    assert.is_nil(runtime._test.hunk_cache[bufnr])
    assert.are.same({}, helpers.get_extmarks(bufnr, ns))
    api.attach(bufnr)
    local new_job = runtime._test.next_syntax_job(bufnr)
    assert.is_false(
      runtime._test.run_deferred_syntax(bufnr, entry.tick, changedtick, old_job, entry.hunks)
    )
    assert.are.same({}, helpers.get_extmarks(bufnr, ns))
    assert.is_true(
      runtime._test.run_deferred_syntax(
        bufnr,
        entry.tick,
        changedtick,
        new_job,
        runtime._test.hunk_cache[bufnr].hunks
      )
    )
    assert.is_true(#helpers.get_extmarks(bufnr, ns) > 0)
  end)
end)
