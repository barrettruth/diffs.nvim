require('spec.helpers')

local diffspec = require('diffs.spec')

describe('diffs.spec', function()
  local path = 'lua/foo.lua'

  it('represents index to worktree file diffs', function()
    local spec = diffspec.index_to_worktree(path)

    assert.are.same({
      left = { kind = 'index' },
      right = { kind = 'worktree' },
      scope = { kind = 'file', path = path },
      mode = 'unified',
    }, spec)
    assert.is_true(diffspec.is_worktree_target(spec))
    assert.is_false(diffspec.is_index_target(spec))
    assert.is_false(diffspec.is_read_only(spec))
    assert.are.same({ read_only = false, target = 'worktree' }, diffspec.mutability(spec))
    assert.are.equal('index -> worktree file:lua/foo.lua', diffspec.label(spec))
  end)

  it('represents HEAD to index file diffs', function()
    local spec = diffspec.head_to_index(path)

    assert.are.same({
      left = { kind = 'tree', rev = 'HEAD' },
      right = { kind = 'index' },
      scope = { kind = 'file', path = path },
      mode = 'unified',
    }, spec)
    assert.is_true(diffspec.is_index_target(spec))
    assert.is_false(diffspec.is_worktree_target(spec))
    assert.is_false(diffspec.is_read_only(spec))
    assert.are.same({ read_only = false, target = 'index' }, diffspec.mutability(spec))
    assert.are.equal('tree:HEAD -> index file:lua/foo.lua', diffspec.label(spec))
  end)

  it('represents revision to worktree file diffs', function()
    local spec = diffspec.rev_to_worktree('feature~2', path)

    assert.are.same({
      left = { kind = 'tree', rev = 'feature~2' },
      right = { kind = 'worktree' },
      scope = { kind = 'file', path = path },
      mode = 'unified',
    }, spec)
    assert.is_true(diffspec.is_worktree_target(spec))
    assert.is_false(diffspec.is_index_target(spec))
    assert.is_false(diffspec.is_read_only(spec))
    assert.are.same({ read_only = false, target = 'worktree' }, diffspec.mutability(spec))
    assert.are.equal('tree:feature~2 -> worktree file:lua/foo.lua', diffspec.label(spec))
  end)

  it('represents read-only revision to revision file diffs', function()
    local spec = diffspec.rev_to_rev('origin/main', 'HEAD', path)

    assert.are.same({
      left = { kind = 'tree', rev = 'origin/main' },
      right = { kind = 'tree', rev = 'HEAD' },
      scope = { kind = 'file', path = path },
      mode = 'unified',
    }, spec)
    assert.is_false(diffspec.is_index_target(spec))
    assert.is_false(diffspec.is_worktree_target(spec))
    assert.is_true(diffspec.is_read_only(spec))
    assert.are.same({ read_only = true }, diffspec.mutability(spec))
    assert.are.equal('tree:origin/main -> tree:HEAD file:lua/foo.lua', diffspec.label(spec))
  end)

  it('normalizes table-shaped specs without keeping caller-owned tables', function()
    local input = {
      left = { kind = 'tree', rev = 'HEAD' },
      right = { kind = 'index' },
      scope = { kind = 'file', path = path },
    }

    local spec = diffspec.new(input)

    input.left.rev = 'changed'
    input.scope.path = 'changed.lua'

    assert.are.equal('HEAD', spec.left.rev)
    assert.are.equal(path, spec.scope.path)
    assert.are.equal('unified', spec.mode)
  end)

  it('rejects unsupported endpoint and scope kinds', function()
    assert.has_error(function()
      diffspec.file({ kind = 'blob', oid = 'abc123' }, diffspec.worktree(), path)
    end, 'diffs: unsupported endpoint kind: blob')

    assert.has_error(function()
      diffspec.new({
        left = diffspec.index(),
        right = diffspec.worktree(),
        scope = { kind = 'repo' },
      })
    end, 'diffs: unsupported scope kind: repo')
  end)
end)
