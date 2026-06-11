local align = require('diffs.split_align')

local function hunk(index, old_start, new_start, lines)
  return {
    index = index,
    old_range = { start = old_start },
    new_range = { start = new_start },
    lines = lines,
  }
end

local function kinds(rows)
  local out = {}
  for i, r in ipairs(rows) do
    out[i] = r.kind
  end
  return out
end

describe('split_align.align', function()
  it('keeps both panes equal length and weaves unchanged context whole-file', function()
    local old_lines = { 'a', 'OLD', 'c' }
    local new_lines = { 'a', 'NEW', 'c' }
    local hunks = { hunk(1, 2, 2, {
      { kind = 'delete', old_lnum = 2 },
      { kind = 'add', new_lnum = 2 },
    }) }

    local r = align.align(old_lines, new_lines, hunks)
    assert.are.same({ 'a', 'OLD', 'c' }, r.left_lines)
    assert.are.same({ 'a', 'NEW', 'c' }, r.right_lines)
    assert.are.equal(#r.left_lines, #r.right_lines)
    assert.are.same({ 'context', 'delete', 'context' }, kinds(r.left_rows))
    assert.are.same({ 'context', 'add', 'context' }, kinds(r.right_rows))
    assert.are.equal(2, r.left_rows[2].old_lnum)
    assert.are.equal(2, r.right_rows[2].new_lnum)
    assert.are.equal(2, r.anchors[1])
  end)

  it('top-aligns an unequal change and pads the shorter side with fillers', function()
    local old_lines = { 'a', 'O1', 'O2', 'd' }
    local new_lines = { 'a', 'N1', 'N2', 'N3', 'd' }
    local hunks = { hunk(1, 2, 2, {
      { kind = 'delete', old_lnum = 2 },
      { kind = 'delete', old_lnum = 3 },
      { kind = 'add', new_lnum = 2 },
      { kind = 'add', new_lnum = 3 },
      { kind = 'add', new_lnum = 4 },
    }) }

    local r = align.align(old_lines, new_lines, hunks)
    assert.are.same({ 'a', 'O1', 'O2', '', 'd' }, r.left_lines)
    assert.are.same({ 'a', 'N1', 'N2', 'N3', 'd' }, r.right_lines)
    assert.are.equal(#r.left_lines, #r.right_lines)
    assert.are.same({ 'context', 'delete', 'delete', 'filler', 'context' }, kinds(r.left_rows))
    assert.are.same({ 'context', 'add', 'add', 'add', 'context' }, kinds(r.right_rows))
  end)

  it('handles a pure-add file as all fillers on the left', function()
    local r = align.align({}, { 'x', 'y' }, { hunk(1, 1, 1, {
      { kind = 'add', new_lnum = 1 },
      { kind = 'add', new_lnum = 2 },
    }) })
    assert.are.same({ '', '' }, r.left_lines)
    assert.are.same({ 'x', 'y' }, r.right_lines)
    assert.are.same({ 'filler', 'filler' }, kinds(r.left_rows))
    assert.are.same({ 'add', 'add' }, kinds(r.right_rows))
  end)

  it('handles a pure-delete file as all fillers on the right', function()
    local r = align.align({ 'x', 'y' }, {}, { hunk(1, 1, 1, {
      { kind = 'delete', old_lnum = 1 },
      { kind = 'delete', old_lnum = 2 },
    }) })
    assert.are.same({ 'x', 'y' }, r.left_lines)
    assert.are.same({ '', '' }, r.right_lines)
    assert.are.same({ 'delete', 'delete' }, kinds(r.left_rows))
    assert.are.same({ 'filler', 'filler' }, kinds(r.right_rows))
  end)

  it('returns empty alignment for no hunks and empty files', function()
    local r = align.align({}, {}, {})
    assert.are.same({}, r.left_lines)
    assert.are.same({}, r.right_lines)
  end)

  it('weaves multiple hunks with unchanged regions between them', function()
    local old_lines = { 'a', 'OLD1', 'b', 'c', 'OLD2', 'e' }
    local new_lines = { 'a', 'NEW1', 'b', 'c', 'NEW2', 'e' }
    local hunks = {
      hunk(1, 2, 2, { { kind = 'delete', old_lnum = 2 }, { kind = 'add', new_lnum = 2 } }),
      hunk(2, 5, 5, { { kind = 'delete', old_lnum = 5 }, { kind = 'add', new_lnum = 5 } }),
    }
    local r = align.align(old_lines, new_lines, hunks)
    assert.are.same(old_lines, r.left_lines)
    assert.are.same(new_lines, r.right_lines)
    assert.are.equal(#r.left_lines, #r.right_lines)
    assert.are.equal(2, r.anchors[1])
    assert.are.equal(5, r.anchors[2])
  end)
end)
