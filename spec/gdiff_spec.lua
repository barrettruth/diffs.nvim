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

  it('parses opt-in stacked layout separately from endpoint parsing', function()
    local result = parse('++layout=stacked HEAD')

    assert.are.same(diffspec.rev_to_worktree('HEAD', path), result.spec)
    assert.is_false(result.novertical)
    assert.are.equal('stacked', result.layout)
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

  it('maps revision explicit-path objects to revision -> worktree of that path', function()
    local result = parse('HEAD:lua/bar.lua')

    assert.are.same(diffspec.rev_to_worktree('HEAD', 'lua/bar.lua'), result.spec)
  end)

  it('normalizes @ in revision explicit-path objects', function()
    local result = parse('@:lua/bar.lua')

    assert.are.same(diffspec.rev_to_worktree('HEAD', 'lua/bar.lua'), result.spec)
  end)

  it('maps index explicit-path objects to index -> worktree of that path', function()
    for _, object in ipairs({ ':lua/bar.lua', ':0:lua/bar.lua' }) do
      local result = parse(object)

      assert.are.same(diffspec.index_to_worktree('lua/bar.lua'), result.spec)
    end
  end)

  it('maps merge-stage current-file objects to stage -> worktree', function()
    for _, stage in ipairs({ 1, 2, 3 }) do
      local result = parse((':%d:%%'):format(stage))

      assert.are.same(diffspec.stage_to_worktree(stage, path), result.spec)
    end
  end)

  it('maps merge-stage explicit-path objects to stage -> worktree of that path', function()
    local result = parse(':3:lua/bar.lua')

    assert.are.same(diffspec.stage_to_worktree(3, 'lua/bar.lua'), result.spec)
  end)

  it('pins explicit-path objects to the worktree even in a staged context', function()
    local result = parse('HEAD:lua/bar.lua', diffspec.index())

    assert.are.same(diffspec.rev_to_worktree('HEAD', 'lua/bar.lua'), result.spec)
  end)

  local rejected = {
    { object = '#', err = 'alternate-buffer objects (#) are not supported' },
    { object = '#2', err = 'alternate-buffer objects (#) are not supported' },
    { object = '!', err = 'owner-commit objects (!) are not supported' },
    { object = '!:lua/bar.lua', err = 'owner-commit objects (!) are not supported' },
    { object = '<cfile>', err = '<cfile> objects are not supported' },
    { object = '-', err = 'the previous-object form (-) is not supported' },
    { object = './lua/bar.lua', err = 'worktree-relative path objects (./) are not supported' },
    { object = '../lua/bar.lua', err = 'worktree-relative path objects (./) are not supported' },
    {
      object = 'main..other',
      err = 'range objects are not supported; use :Diff review for ranges',
    },
    {
      object = 'main...other',
      err = 'range objects are not supported; use :Diff review for ranges',
    },
    { object = ':2', err = 'merge stage :2 needs a path; use :2:% for the current file' },
    { object = ':/fix', err = 'commit-message search objects (:/) are not supported' },
    { object = ':(top)lua/bar.lua', err = 'pathspec-magic objects (:(...)) are not supported' },
    { object = 'master:', err = 'tree objects (trailing :) are not supported' },
  }

  for _, case in ipairs(rejected) do
    it('rejects ' .. case.object, function()
      local result, err = gdiff.parse(case.object, { path = path })

      assert.is_nil(result)
      assert.are.equal(case.err, err)
    end)
  end
end)
