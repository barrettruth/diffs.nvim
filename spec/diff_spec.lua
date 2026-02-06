require('spec.helpers')
local diff = require('diffs.diff')

describe('diff', function()
  describe('extract_change_groups', function()
    it('returns empty for all context lines', function()
      local groups = diff.extract_change_groups({ ' line1', ' line2', ' line3' })
      assert.are.equal(0, #groups)
    end)

    it('returns empty for pure additions', function()
      local groups = diff.extract_change_groups({ '+line1', '+line2' })
      assert.are.equal(0, #groups)
    end)

    it('returns empty for pure deletions', function()
      local groups = diff.extract_change_groups({ '-line1', '-line2' })
      assert.are.equal(0, #groups)
    end)

    it('extracts single change group', function()
      local groups = diff.extract_change_groups({
        ' context',
        '-old line',
        '+new line',
        ' context',
      })
      assert.are.equal(1, #groups)
      assert.are.equal(1, #groups[1].del_lines)
      assert.are.equal(1, #groups[1].add_lines)
      assert.are.equal('old line', groups[1].del_lines[1].text)
      assert.are.equal('new line', groups[1].add_lines[1].text)
    end)

    it('extracts multiple change groups separated by context', function()
      local groups = diff.extract_change_groups({
        '-old1',
        '+new1',
        ' context',
        '-old2',
        '+new2',
      })
      assert.are.equal(2, #groups)
      assert.are.equal('old1', groups[1].del_lines[1].text)
      assert.are.equal('new1', groups[1].add_lines[1].text)
      assert.are.equal('old2', groups[2].del_lines[1].text)
      assert.are.equal('new2', groups[2].add_lines[1].text)
    end)

    it('tracks correct line indices', function()
      local groups = diff.extract_change_groups({
        ' context',
        '-deleted',
        '+added',
      })
      assert.are.equal(2, groups[1].del_lines[1].idx)
      assert.are.equal(3, groups[1].add_lines[1].idx)
    end)

    it('handles multiple del lines followed by multiple add lines', function()
      local groups = diff.extract_change_groups({
        '-del1',
        '-del2',
        '+add1',
        '+add2',
        '+add3',
      })
      assert.are.equal(1, #groups)
      assert.are.equal(2, #groups[1].del_lines)
      assert.are.equal(3, #groups[1].add_lines)
    end)
  end)

  describe('compute_intra_hunks', function()
    it('returns nil for all-addition hunks', function()
      local result = diff.compute_intra_hunks({ '+line1', '+line2' }, 'native')
      assert.is_nil(result)
    end)

    it('returns nil for all-deletion hunks', function()
      local result = diff.compute_intra_hunks({ '-line1', '-line2' }, 'native')
      assert.is_nil(result)
    end)

    it('returns nil for context-only hunks', function()
      local result = diff.compute_intra_hunks({ ' line1', ' line2' }, 'native')
      assert.is_nil(result)
    end)

    it('returns spans for single word change', function()
      local result = diff.compute_intra_hunks({
        '-local x = 1',
        '+local x = 2',
      }, 'native')
      assert.is_not_nil(result)
      assert.is_true(#result.del_spans > 0)
      assert.is_true(#result.add_spans > 0)
    end)

    it('identifies correct byte offsets for word change', function()
      local result = diff.compute_intra_hunks({
        '-local x = 1',
        '+local x = 2',
      }, 'native')
      assert.is_not_nil(result)

      assert.are.equal(1, #result.del_spans)
      assert.are.equal(1, #result.add_spans)
      local del_span = result.del_spans[1]
      local add_span = result.add_spans[1]
      local del_text = ('local x = 1'):sub(del_span.col_start, del_span.col_end - 1)
      local add_text = ('local x = 2'):sub(add_span.col_start, add_span.col_end - 1)
      assert.are.equal('1', del_text)
      assert.are.equal('2', add_text)
    end)

    it('handles multiple change groups separated by context', function()
      local result = diff.compute_intra_hunks({
        '-local a = 1',
        '+local a = 2',
        ' local b = 3',
        '-local c = 4',
        '+local c = 5',
      }, 'native')
      assert.is_not_nil(result)
      assert.is_true(#result.del_spans >= 2)
      assert.is_true(#result.add_spans >= 2)
    end)

    it('handles uneven line counts (2 old, 1 new)', function()
      local result = diff.compute_intra_hunks({
        '-line one',
        '-line two',
        '+line combined',
      }, 'native')
      assert.is_not_nil(result)
    end)

    it('handles multi-byte UTF-8 content', function()
      local result = diff.compute_intra_hunks({
        '-local x = "héllo"',
        '+local x = "wörld"',
      }, 'native')
      assert.is_not_nil(result)
      assert.is_true(#result.del_spans > 0)
      assert.is_true(#result.add_spans > 0)
    end)

    it('returns nil when del and add are identical', function()
      local result = diff.compute_intra_hunks({
        '-local x = 1',
        '+local x = 1',
      }, 'native')
      assert.is_nil(result)
    end)
  end)

  describe('has_vscode', function()
    it('returns false in test environment', function()
      assert.is_false(diff.has_vscode())
    end)
  end)
end)
