require('spec.helpers')

local diff = require('diffs.diff')
local diffopt = require('diffs.diffopt')
local render = require('diffs.render')

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

  it('maps flags onto the equivalent git diff flags', function()
    vim.o.diffopt = 'internal,iwhiteall'
    assert.are.same({ '--ignore-all-space' }, diffopt.git_flags())

    vim.o.diffopt = 'internal,iwhite'
    assert.are.same({ '--ignore-space-change' }, diffopt.git_flags())

    vim.o.diffopt = 'internal,iwhiteeol'
    assert.are.same({ '--ignore-space-at-eol' }, diffopt.git_flags())

    vim.o.diffopt = 'internal,iblank'
    assert.are.same({ '--ignore-blank-lines' }, diffopt.git_flags())

    vim.o.diffopt = 'internal,algorithm:histogram'
    assert.are.same({ '--diff-algorithm=histogram' }, diffopt.git_flags())
  end)

  it('omits linematch from git flags (no git equivalent)', function()
    vim.o.diffopt = 'internal,linematch:60'
    assert.are.same({}, diffopt.git_flags())
  end)

  it('combines whitespace and algorithm git flags', function()
    vim.o.diffopt = 'internal,iwhiteall,algorithm:patience'
    local flags = diffopt.git_flags()
    assert.is_true(vim.tbl_contains(flags, '--ignore-all-space'))
    assert.is_true(vim.tbl_contains(flags, '--diff-algorithm=patience'))
  end)
end)

describe('git-backed diffs honor diffopt whitespace', function()
  local review = require('diffs.review')
  local saved

  before_each(function()
    saved = vim.o.diffopt
  end)

  after_each(function()
    vim.o.diffopt = saved
  end)

  it('splices whitespace flags into the review diff command', function()
    vim.o.diffopt = 'internal'
    local plain = review.build_cmd({ repo_root = '/repo', exec_args = { 'HEAD' } })
    assert.is_false(vim.tbl_contains(plain, '--ignore-all-space'))

    vim.o.diffopt = 'internal,iwhiteall'
    local ignored = review.build_cmd({ repo_root = '/repo', exec_args = { 'HEAD' } })
    assert.is_true(vim.tbl_contains(ignored, '--ignore-all-space'))
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

describe('diffopt change handler', function()
  it('exposes on_diffopt_changed', function()
    assert.are.equal('function', type(require('diffs.commands').on_diffopt_changed))
  end)
end)

describe('line-level whitespace handling', function()
  local saved

  before_each(function()
    saved = vim.o.diffopt
  end)

  after_each(function()
    vim.o.diffopt = saved
  end)

  it('drops a whitespace-only change when iwhiteall is set', function()
    local old = { 'local x = 1', 'keep' }
    local new = { 'local x = 1  ', 'keep' }

    vim.o.diffopt = 'internal,filler'
    assert.is_true(#render.unified_lines(old, new, 'f', 'f') > 0)

    vim.o.diffopt = 'internal,filler,iwhiteall'
    assert.are.same({}, render.unified_lines(old, new, 'f', 'f'))
  end)

  it('keeps a content change that also touches whitespace', function()
    local old = { 'local x = 1', 'keep' }
    local new = { 'local y = 1  ', 'keep' }

    vim.o.diffopt = 'internal,filler,iwhiteall'
    assert.is_true(#render.unified_lines(old, new, 'f', 'f') > 0)
  end)
end)

describe('intra-line whitespace handling (default algorithm)', function()
  local saved

  before_each(function()
    saved = vim.o.diffopt
  end)

  after_each(function()
    vim.o.diffopt = saved
  end)

  it('highlights a whitespace-only intra change by default', function()
    vim.o.diffopt = 'internal'
    local result = diff.compute_intra_hunks({ '-foo bar', '+foo  bar' }, 'default')
    assert.is_not_nil(result)
    assert.is_true(#result.add_spans > 0 or #result.del_spans > 0)
  end)

  it('drops whitespace-only intra spans when iwhiteall is set', function()
    vim.o.diffopt = 'internal,iwhiteall'
    local result = diff.compute_intra_hunks({ '-foo bar', '+foo  bar' }, 'default')
    assert.is_nil(result)
  end)

  it('keeps content spans while dropping whitespace spans under iwhiteall', function()
    vim.o.diffopt = 'internal,iwhiteall'
    local result = diff.compute_intra_hunks({ '-foo', '+bar  ' }, 'default')
    assert.is_not_nil(result)
    assert.is_true(#result.add_spans > 0)
  end)

  it('keeps whitespace intra spans under iwhite (only iwhiteall drops them)', function()
    vim.o.diffopt = 'internal,iwhite'
    local result = diff.compute_intra_hunks({ '-ab', '+a b' }, 'default')
    assert.is_not_nil(result)
  end)

  it('drops only end-of-line whitespace spans under iwhiteeol', function()
    vim.o.diffopt = 'internal,iwhiteeol'
    assert.is_nil(diff.compute_intra_hunks({ '-foo', '+foo  ' }, 'default'))
    assert.is_not_nil(diff.compute_intra_hunks({ '-foo  bar', '+foo bar' }, 'default'))
  end)

  it('does not drop a multibyte content change under iwhiteall', function()
    vim.o.diffopt = 'internal,iwhiteall'
    local result = diff.compute_intra_hunks({ '-café', '+cafe' }, 'default')
    assert.is_not_nil(result)
  end)
end)
