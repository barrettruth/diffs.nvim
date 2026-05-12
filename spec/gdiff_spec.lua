require('spec.helpers')

local diffspec = require('diffs.spec')
local gdiff = require('diffs.gdiff')

describe('diffs.gdiff', function()
  local path = 'lua/foo.lua'

  local function parse(args, current)
    local result, err = gdiff.parse(args, {
      path = path,
      current = current or diffspec.worktree(),
    })
    assert.is_nil(err)
    return result
  end

  it('maps default worktree :Gdiff to index -> worktree', function()
    local result = parse(nil)

    assert.are.same(diffspec.index_to_worktree(path), result.spec)
    assert.is_false(result.novertical)
    assert.are.equal('unified', result.layout)
  end)

  it('maps explicit revisions to revision -> worktree', function()
    local result = parse('HEAD~3')

    assert.are.same(diffspec.rev_to_worktree('HEAD~3', path), result.spec)
  end)

  it('normalizes @ as HEAD', function()
    local result = parse('@')

    assert.are.same(diffspec.rev_to_worktree('HEAD', path), result.spec)
  end)

  it('maps current-file index objects to index -> worktree', function()
    for _, object in ipairs({ ':', ':%', ':0:%' }) do
      local result = parse(object)

      assert.are.same(diffspec.index_to_worktree(path), result.spec)
    end
  end)

  it('maps revision current-file objects to tree -> worktree', function()
    local result = parse('@:%')

    assert.are.same(diffspec.rev_to_worktree('HEAD', path), result.spec)
  end)

  it('maps staged/index context default to HEAD -> index', function()
    local result = parse(nil, diffspec.index())

    assert.are.same(diffspec.head_to_index(path), result.spec)
  end)

  it('maps staged/index context @:% to HEAD -> index', function()
    local result = parse('@:%', diffspec.index())

    assert.are.same(diffspec.head_to_index(path), result.spec)
  end)

  it('keeps ++novertical separate from endpoint parsing', function()
    local result = parse('++novertical HEAD')

    assert.are.same(diffspec.rev_to_worktree('HEAD', path), result.spec)
    assert.is_true(result.novertical)
    assert.are.equal('unified', result.layout)
  end)

  it('parses opt-in split layout separately from endpoint parsing', function()
    local result = parse('++layout=split HEAD')

    assert.are.same(diffspec.rev_to_worktree('HEAD', path), result.spec)
    assert.is_false(result.novertical)
    assert.are.equal('split', result.layout)
  end)

  it('allows explicit unified layout', function()
    local result = parse('++layout=unified HEAD')

    assert.are.same(diffspec.rev_to_worktree('HEAD', path), result.spec)
    assert.are.equal('unified', result.layout)
  end)

  it('rejects repeated layout options', function()
    local result, err = gdiff.parse('++layout=split ++layout=unified HEAD', { path = path })

    assert.is_nil(result)
    assert.are.equal('repeated ++layout option', err)
  end)

  it('rejects unsupported layouts', function()
    local result, err = gdiff.parse('++layout=tiled HEAD', { path = path })

    assert.is_nil(result)
    assert.are.equal('unsupported layout tiled', err)
  end)

  it('rejects unknown ++ options', function()
    local result, err = gdiff.parse('++bogus HEAD', { path = path })

    assert.is_nil(result)
    assert.are.equal('unknown option ++bogus', err)
  end)

  it('rejects --staged as an unsupported flag', function()
    local result, err = gdiff.parse('--staged', { path = path })

    assert.is_nil(result)
    assert.are.equal('unsupported option --staged', err)
  end)

  it('rejects multiple objects', function()
    local result, err = gdiff.parse('HEAD :0:%', { path = path })

    assert.is_nil(result)
    assert.are.equal('expected at most one Fugitive object', err)
  end)

  it('rejects unsupported index stages for now', function()
    local result, err = gdiff.parse(':2:%', { path = path })

    assert.is_nil(result)
    assert.are.equal('unsupported index stage :2:%', err)
  end)
end)
