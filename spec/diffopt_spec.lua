require('spec.helpers')

local diff = require('diffs.diff')
local diffopt = require('diffs.diffopt')

describe('diffopt resolver', function()
  local saved

  before_each(function()
    saved = vim.o.diffopt
  end)

  after_each(function()
    vim.o.diffopt = saved
  end)

  it('maps whitespace flags onto vim.diff option names', function()
    vim.o.diffopt = 'internal,filler,iwhite'
    assert.are.same({ ignore_whitespace_change = true }, diffopt.resolve())

    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same({ ignore_whitespace = true }, diffopt.resolve())

    vim.o.diffopt = 'internal,iwhiteeol'
    assert.are.same({ ignore_whitespace_change_at_eol = true }, diffopt.resolve())

    vim.o.diffopt = 'internal,iblank'
    assert.are.same({ ignore_blank_lines = true }, diffopt.resolve())
  end)

  it('resolves algorithm and linematch', function()
    vim.o.diffopt = 'internal,algorithm:patience,linematch:60'
    local opts = diffopt.resolve()
    assert.are.equal('patience', opts.algorithm)
    assert.are.equal(60, opts.linematch)
  end)

  it('resolves every inline granularity', function()
    for _, mode in ipairs({ 'none', 'simple', 'char', 'word' }) do
      vim.o.diffopt = 'internal,filler,inline:' .. mode
      assert.are.equal(mode, diffopt.resolve().inline)
      assert.are.equal(mode, diffopt.inline())
    end
  end)

  it('treats a missing inline value as simple, like Neovim does', function()
    vim.o.diffopt = 'internal,filler'
    assert.is_nil(diffopt.resolve().inline)
    assert.are.equal('simple', diffopt.inline())
  end)

  it('omits inline from vim.text.diff options', function()
    vim.o.diffopt = 'internal,inline:word,iwhiteall'
    assert.are.same({ ignore_whitespace = true }, diffopt.vim_diff_opts())
  end)
end)

describe('whitespace-only line classification', function()
  local saved

  before_each(function()
    saved = vim.o.diffopt
  end)

  after_each(function()
    vim.o.diffopt = saved
  end)

  it('returns an empty set when no whitespace flag is active', function()
    vim.o.diffopt = 'internal,filler'
    assert.are.same({}, diff.whitespace_only_lines({ '-foo bar', '+foo  bar' }))
  end)

  it('flags a whitespace-only -/+ pair under iwhiteall', function()
    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same(
      { [1] = true, [2] = true },
      diff.whitespace_only_lines({ '-foo bar', '+foo  bar' })
    )
  end)

  it('does not flag a content change under iwhiteall', function()
    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same({}, diff.whitespace_only_lines({ '-foo', '+bar' }))
  end)

  it('does not flag a line that mixes content and whitespace', function()
    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same({}, diff.whitespace_only_lines({ '-local x = 1', '+local y = 1  ' }))
  end)

  it('collapses whitespace runs under iwhite', function()
    vim.o.diffopt = 'internal,iwhite'
    assert.are.same(
      { [1] = true, [2] = true },
      diff.whitespace_only_lines({ '-foo  bar', '+foo bar' })
    )
  end)

  it('flags only trailing differences under iwhiteeol', function()
    vim.o.diffopt = 'internal,iwhiteeol'
    assert.are.same({ [1] = true, [2] = true }, diff.whitespace_only_lines({ '-foo', '+foo  ' }))
    assert.are.same({}, diff.whitespace_only_lines({ '-foo  bar', '+foo bar' }))
  end)

  it('ignores unpaired additions and deletions', function()
    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same({}, diff.whitespace_only_lines({ ' context', '+added line' }))
  end)

  it('classifies a reindented multi-line block', function()
    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same(
      { [1] = true, [2] = true, [3] = true, [4] = true },
      diff.whitespace_only_lines({
        '-  function foo()',
        '-    return 1',
        '+    function foo()',
        '+      return 1',
      })
    )
  end)

  it('classifies a reindented multi-line block when linematch is set', function()
    vim.o.diffopt = 'internal,iwhiteall,linematch:60'
    assert.are.same(
      { [1] = true, [2] = true, [3] = true, [4] = true },
      diff.whitespace_only_lines({
        '-  function foo()',
        '-    return 1',
        '+    function foo()',
        '+      return 1',
      })
    )
  end)

  it('treats a trailing-only multibyte change as whitespace-only under iwhiteall', function()
    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same(
      { [1] = true, [2] = true },
      diff.whitespace_only_lines({ '-café', '+café  ' })
    )
  end)

  it('flags a blank-line-only change under iwhiteall', function()
    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same({ [1] = true, [2] = true }, diff.whitespace_only_lines({ '-  ', '+    ' }))
  end)
end)

describe('intra-line whitespace handling', function()
  local saved

  before_each(function()
    saved = vim.o.diffopt
  end)

  after_each(function()
    vim.o.diffopt = saved
  end)

  it('highlights a whitespace-only intra change by default', function()
    vim.o.diffopt = 'internal'
    local result = diff.compute_intra_hunks({ '-foo bar', '+foo  bar' })
    assert.is_not_nil(result)
    assert.is_true(#result.add_spans > 0 or #result.del_spans > 0)
  end)

  it('drops whitespace-only intra spans when iwhiteall is set', function()
    vim.o.diffopt = 'internal,iwhiteall'
    local result = diff.compute_intra_hunks({ '-foo bar', '+foo  bar' })
    assert.is_nil(result)
  end)

  it('keeps content spans while dropping whitespace spans under iwhiteall', function()
    vim.o.diffopt = 'internal,iwhiteall'
    local result = diff.compute_intra_hunks({ '-foo', '+bar  ' })
    assert.is_not_nil(result)
    assert.is_true(#result.add_spans > 0)
  end)

  it('keeps whitespace intra spans under iwhite (only iwhiteall drops them)', function()
    vim.o.diffopt = 'internal,iwhite'
    local result = diff.compute_intra_hunks({ '-ab', '+a b' })
    assert.is_not_nil(result)
  end)

  it('drops only end-of-line whitespace spans under iwhiteeol', function()
    vim.o.diffopt = 'internal,iwhiteeol'
    assert.is_nil(diff.compute_intra_hunks({ '-foo', '+foo  ' }))
    assert.is_not_nil(diff.compute_intra_hunks({ '-foo  bar', '+foo bar' }))
  end)

  it('does not drop a multibyte content change under iwhiteall', function()
    vim.o.diffopt = 'internal,iwhiteall'
    local result = diff.compute_intra_hunks({ '-café', '+cafe' })
    assert.is_not_nil(result)
  end)
end)
