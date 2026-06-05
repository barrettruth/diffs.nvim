local helpers = require('spec.helpers')

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
      prefix_width = 12,
      separator_width = 5,
      style = 'dual',
    }, info)
    assert.are.equal('        │ diff --git a/file.txt b/file.txt', annotated[1])
    assert.are.equal('        │ @@ -9,3 +10,4 @@', annotated[4])
    assert.are.equal('   9 10 │  alpha', annotated[5])
    assert.are.equal('  10    │ -beta', annotated[6])
    assert.are.equal('     11 │ +beta changed', annotated[7])
    assert.are.equal('  11 12 │  gamma', annotated[8])
    assert.are.equal('     13 │ +delta', annotated[9])
    assert.are.equal('        │ \\ No newline at end of file', annotated[10])
  end)

  it('leaves non-diff content unchanged', function()
    local lines = { 'not a diff' }
    local annotated, info = rails.annotate(lines)

    assert.are.equal(lines, annotated)
    assert.is_nil(info)
  end)

  it('adds a single side-aware line-number rail to unified diff lines', function()
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
    }, { rail_style = 'single' })

    assert.are.same({
      width = 2,
      prefix_width = 9,
      separator_width = 5,
      style = 'single',
    }, info)
    assert.are.equal('     │ diff --git a/file.txt b/file.txt', annotated[1])
    assert.are.equal('     │ @@ -9,3 +10,4 @@', annotated[4])
    assert.are.equal('  10 │  alpha', annotated[5])
    assert.are.equal('  10 │ -beta', annotated[6])
    assert.are.equal('  11 │ +beta changed', annotated[7])
    assert.are.equal('  12 │  gamma', annotated[8])
    assert.are.equal('  13 │ +delta', annotated[9])
    assert.are.equal('     │ \\ No newline at end of file', annotated[10])
  end)

  it('does not render trailing spaces for empty context lines', function()
    local annotated, info = rails.annotate({
      'diff --git a/file.txt b/file.txt',
      '@@ -1,2 +1,2 @@',
      ' line',
      ' ',
    })

    assert.are.same({
      width = 1,
      prefix_width = 10,
      separator_width = 5,
      style = 'dual',
    }, info)
    assert.are.equal('  2 2 │', annotated[4])
    assert.is_nil(annotated[4]:match('%s$'))
    assert.are.equal(' ', rails.strip(annotated[4], info.prefix_width))
  end)

  it('strips single rail display lines back to raw unified diff lines', function()
    local lines = {
      'diff --git a/file.txt b/file.txt',
      '@@ -1,3 +1,3 @@',
      ' first',
      ' ',
      '-old',
      '+new',
    }
    local annotated, info = rails.annotate(lines, { rail_style = 'single' })

    assert.are.equal('  2 │', annotated[4])
    assert.is_nil(annotated[4]:match('%s$'))
    assert.are.equal(' ', rails.strip(annotated[4], info.prefix_width, info.separator_width))
    assert.are.same(lines, rails.strip_lines(annotated, info.prefix_width, info.separator_width))
  end)

  it('returns byte ranges for old and new rail number columns', function()
    assert.are.same({
      old_start = 2,
      old_end = 4,
      new_start = 5,
      new_end = 7,
    }, rails.ranges(12))
  end)

  it('returns style-aware byte ranges for rail number columns', function()
    assert.are.same({
      {
        start = 2,
        finish = 4,
      },
      {
        start = 5,
        finish = 7,
      },
    }, rails.number_ranges(12, nil, 'dual'))
    assert.are.same({
      {
        start = 2,
        finish = 4,
      },
    }, rails.number_ranges(9, nil, 'single'))
  end)

  it('supports custom rail separators', function()
    local annotated, info = rails.annotate({
      'diff --git a/file.txt b/file.txt',
      '@@ -9,2 +10,2 @@',
      ' alpha',
      '+beta',
    }, { rail_separator = '|' })

    assert.are.same({
      width = 2,
      prefix_width = 10,
      separator_width = 3,
      style = 'dual',
    }, info)
    assert.are.equal('        | diff --git a/file.txt b/file.txt', annotated[1])
    assert.are.equal('   9 10 |  alpha', annotated[3])
    assert.are.equal('     11 | +beta', annotated[4])
    assert.are.same({
      old_start = 2,
      old_end = 4,
      new_start = 5,
      new_end = 7,
    }, rails.ranges(info.prefix_width, info.separator_width))
  end)

  it('supports empty custom rail separators for single rails', function()
    local annotated, info = rails.annotate({
      'diff --git a/file.txt b/file.txt',
      '@@ -9,2 +10,2 @@',
      ' alpha',
      '+beta',
    }, { rail_style = 'single', rail_separator = '' })

    assert.are.same({
      width = 2,
      prefix_width = 6,
      separator_width = 2,
      style = 'single',
    }, info)
    assert.are.equal('      diff --git a/file.txt b/file.txt', annotated[1])
    assert.are.equal('  10   alpha', annotated[3])
    assert.are.equal('  11  +beta', annotated[4])
    assert.are.equal(' alpha', rails.strip(annotated[3], info.prefix_width, info.separator_width))
    assert.are.same({
      {
        start = 2,
        finish = 4,
      },
    }, rails.number_ranges(info.prefix_width, info.separator_width, info.style))
  end)

  it('reads buffer rail style with a dual compatibility default', function()
    local bufnr = helpers.create_buffer({})

    assert.are.equal('dual', rails.style_for_buffer(bufnr))

    vim.api.nvim_buf_set_var(bufnr, 'diffs_rail_style', 'single')
    assert.are.equal('single', rails.style_for_buffer(bufnr))

    vim.api.nvim_buf_set_var(bufnr, 'diffs_rail_style', 'dual')
    assert.are.equal('dual', rails.style_for_buffer(bufnr))

    vim.api.nvim_buf_set_var(bufnr, 'diffs_rail_style', 'stacked')
    assert.are.equal('dual', rails.style_for_buffer(bufnr))

    pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_rail_style')
    assert.are.equal('dual', rails.style_for_buffer(bufnr))

    helpers.delete_buffer(bufnr)
  end)
end)
