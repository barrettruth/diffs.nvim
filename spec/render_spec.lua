require('spec.helpers')

local diffspec = require('diffs.spec')
local git = require('diffs.git')
local render = require('diffs.render')

local saved_git = {}

local function mock_git_content()
  saved_git.get_file_content = git.get_file_content
  saved_git.get_index_content = git.get_index_content
  saved_git.get_working_content = git.get_working_content

  git.get_file_content = function(rev, filepath)
    assert.are.equal('/tmp/repo/foo.lua', filepath)
    if rev == 'HEAD' then
      return { 'return "head"' }
    end
    if rev == 'HEAD~1' then
      return { 'return "older"' }
    end
    if rev == 'feature' then
      return { 'return "feature"' }
    end
    return nil, 'unknown rev'
  end

  git.get_index_content = function(filepath)
    assert.are.equal('/tmp/repo/foo.lua', filepath)
    return { 'return "index"' }
  end

  git.get_working_content = function(filepath)
    assert.are.equal('/tmp/repo/foo.lua', filepath)
    return { 'return "worktree"' }
  end
end

local function restore_mocks()
  for k, v in pairs(saved_git) do
    git[k] = v
  end
  saved_git = {}
end

local function render_text(spec)
  local lines, err = render.file(spec, '/tmp/repo')
  assert.is_nil(err)
  assert.is_not_nil(lines)
  return table.concat(lines, '\n')
end

describe('diffs.render', function()
  after_each(function()
    restore_mocks()
  end)

  it('renders index to worktree edges separately from staged changes', function()
    mock_git_content()

    local text = render_text(diffspec.index_to_worktree('foo.lua'))

    assert.is_true(text:find('-return "index"', 1, true) ~= nil)
    assert.is_true(text:find('+return "worktree"', 1, true) ~= nil)
    assert.is_false(text:find('return "head"', 1, true) ~= nil)
  end)

  it('renders HEAD to index edges separately from unstaged changes', function()
    mock_git_content()

    local text = render_text(diffspec.head_to_index('foo.lua'))

    assert.is_true(text:find('-return "head"', 1, true) ~= nil)
    assert.is_true(text:find('+return "index"', 1, true) ~= nil)
    assert.is_false(text:find('return "worktree"', 1, true) ~= nil)
  end)

  it('renders arbitrary tree to index edges', function()
    mock_git_content()

    local text = render_text(diffspec.file(diffspec.tree('HEAD~1'), diffspec.index(), 'foo.lua'))

    assert.is_true(text:find('-return "older"', 1, true) ~= nil)
    assert.is_true(text:find('+return "index"', 1, true) ~= nil)
    assert.is_false(text:find('return "worktree"', 1, true) ~= nil)
  end)

  it('renders revision to worktree edges', function()
    mock_git_content()

    local text = render_text(diffspec.rev_to_worktree('HEAD~1', 'foo.lua'))

    assert.is_true(text:find('-return "older"', 1, true) ~= nil)
    assert.is_true(text:find('+return "worktree"', 1, true) ~= nil)
  end)

  it('renders read-only revision to revision edges', function()
    local calls = {}
    mock_git_content()
    git.get_file_content = function(rev, filepath)
      table.insert(calls, { rev, filepath })
      if rev == 'HEAD~1' then
        return { 'return "older"' }
      end
      if rev == 'feature' then
        return { 'return "feature"' }
      end
      return nil, 'unknown rev'
    end

    local text = render_text(diffspec.rev_to_rev('HEAD~1', 'feature', 'foo.lua'))

    assert.are.same({
      { 'HEAD~1', '/tmp/repo/foo.lua' },
      { 'feature', '/tmp/repo/foo.lua' },
    }, calls)
    assert.is_true(text:find('-return "older"', 1, true) ~= nil)
    assert.is_true(text:find('+return "feature"', 1, true) ~= nil)
  end)

  it('can render against current unsaved worktree lines', function()
    mock_git_content()

    local lines, err = render.file(diffspec.rev_to_worktree('HEAD', 'foo.lua'), '/tmp/repo', {
      worktree_lines = { 'return "buffer"' },
    })

    assert.is_nil(err)
    local text = table.concat(lines, '\n')
    assert.is_true(text:find('-return "head"', 1, true) ~= nil)
    assert.is_true(text:find('+return "buffer"', 1, true) ~= nil)
    assert.is_false(text:find('return "worktree"', 1, true) ~= nil)
  end)
end)
