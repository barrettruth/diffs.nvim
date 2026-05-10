require('spec.helpers')

local rails = require('diffs.rails')

describe('diffs.rails', function()
  it('adds old and new line-number rails to unified diff lines', function()
    local annotated, info = rails.annotate({
      'diff --git a/file.txt b/file.txt',
      '--- a/file.txt',
      '+++ b/file.txt',
      '@@ -9,3 +10,4 @@',
      ' alpha',
      '-beta',
      '+beta changed',
      ' gamma',
      '+delta',
      '\\ No newline at end of file',
    })

    assert.are.same({
      width = 2,
      prefix_width = 8,
    }, info)
    assert.are.equal('      | diff --git a/file.txt b/file.txt', annotated[1])
    assert.are.equal('      | @@ -9,3 +10,4 @@', annotated[4])
    assert.are.equal(' 9 10 |  alpha', annotated[5])
    assert.are.equal('10    | -beta', annotated[6])
    assert.are.equal('   11 | +beta changed', annotated[7])
    assert.are.equal('11 12 |  gamma', annotated[8])
    assert.are.equal('   13 | +delta', annotated[9])
    assert.are.equal('      | \\ No newline at end of file', annotated[10])
  end)

  it('leaves non-diff content unchanged', function()
    local lines = { 'not a diff' }
    local annotated, info = rails.annotate(lines)

    assert.are.equal(lines, annotated)
    assert.is_nil(info)
  end)
end)
