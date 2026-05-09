require('spec.helpers')

local diffspec = require('diffs.spec')
local git = require('diffs.git')
local render = require('diffs.render')

local saved_git = {}
local test_repos = {}

local function git_cmd(repo_root, args)
  local cmd = { 'git', '-C', repo_root }
  for _, arg in ipairs(args) do
    cmd[#cmd + 1] = arg
  end
  local output = vim.fn.systemlist(cmd)
  assert.are.equal(0, vim.v.shell_error, table.concat(output, '\n'))
  return output
end

local function create_repo()
  local repo_root = vim.fn.tempname()
  vim.fn.mkdir(repo_root, 'p')
  test_repos[#test_repos + 1] = repo_root

  vim.fn.systemlist({ 'git', 'init', '-q', repo_root })
  assert.are.equal(0, vim.v.shell_error)
  git_cmd(repo_root, { 'config', 'user.email', 'test@example.com' })
  git_cmd(repo_root, { 'config', 'user.name', 'Test' })
  vim.fn.writefile({ 'line 1', 'line 2' }, repo_root .. '/file.txt')
  git_cmd(repo_root, { 'add', 'file.txt' })
  git_cmd(repo_root, { 'commit', '-qm', 'initial' })

  return repo_root
end

local function write_binary_file(path, text)
  vim.fn.system({ 'sh', '-c', 'printf "$1" > "$2"', 'sh', text, path })
  assert.are.equal(0, vim.v.shell_error)
end

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
  for _, repo_root in ipairs(test_repos) do
    vim.fn.delete(repo_root, 'rf')
  end
  test_repos = {}
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

  it('renders untracked files as index to worktree additions', function()
    local repo_root = create_repo()
    vim.fn.writefile({ 'new file' }, repo_root .. '/new.txt')

    local lines, err = render.file(diffspec.index_to_worktree('new.txt'), repo_root)

    assert.is_nil(err)
    local text = table.concat(lines, '\n')
    assert.is_true(text:find('new file mode 100644', 1, true) ~= nil)
    assert.is_true(text:find('--- /dev/null', 1, true) ~= nil)
    assert.is_true(text:find('+new file', 1, true) ~= nil)
  end)

  it('renders staged deletions as HEAD to index deletions', function()
    local repo_root = create_repo()
    vim.fn.delete(repo_root .. '/file.txt')
    git_cmd(repo_root, { 'add', '-u', 'file.txt' })

    local lines, err = render.file(diffspec.head_to_index('file.txt'), repo_root)

    assert.is_nil(err)
    local text = table.concat(lines, '\n')
    assert.is_true(text:find('deleted file mode 100644', 1, true) ~= nil)
    assert.is_true(text:find('+++ /dev/null', 1, true) ~= nil)
    assert.is_true(text:find('-line 1', 1, true) ~= nil)
  end)

  it('renders clean index to worktree edges as empty diffs', function()
    local repo_root = create_repo()

    local lines, err = render.file(diffspec.index_to_worktree('file.txt'), repo_root)

    assert.is_nil(err)
    assert.are.same({}, lines)
  end)

  it('renders clean HEAD to index edges as empty diffs', function()
    local repo_root = create_repo()

    local lines, err = render.file(diffspec.head_to_index('file.txt'), repo_root)

    assert.is_nil(err)
    assert.are.same({}, lines)
  end)

  it('preserves real trailing blank line changes', function()
    local repo_root = create_repo()
    vim.fn.writefile({ 'line 1', 'line 2', '' }, repo_root .. '/file.txt')

    local lines, err = render.file(diffspec.index_to_worktree('file.txt'), repo_root)

    assert.is_nil(err)
    local text = table.concat(lines, '\n')
    assert.is_true(text:find('\n+\n', 1, true) ~= nil)
  end)

  it('renders final-newline-only changes with no-newline metadata', function()
    local repo_root = create_repo()
    vim.fn.writefile({ 'line 1', 'line 2' }, repo_root .. '/file.txt', 'b')

    local lines, err = render.file(diffspec.index_to_worktree('file.txt'), repo_root)

    assert.is_nil(err)
    local text = table.concat(lines, '\n')
    assert.is_true(text:find('-line 2', 1, true) ~= nil)
    assert.is_true(text:find('+line 2', 1, true) ~= nil)
    assert.is_true(text:find('\\ No newline at end of file', 1, true) ~= nil)
  end)

  it('rejects same-path rename projections before rendering actionable hunks', function()
    local repo_root = create_repo()
    git_cmd(repo_root, { 'mv', 'file.txt', 'renamed.txt' })

    local lines, err = render.file(diffspec.head_to_index('renamed.txt'), repo_root)

    assert.is_nil(lines)
    assert.are.equal('Gdiff does not support rename or copy changes', err)
  end)

  it('rejects mode-only changes because there are no text hunks to apply', function()
    local repo_root = create_repo()
    vim.fn.setfperm(repo_root .. '/file.txt', 'rwxr-xr-x')

    local lines, err = render.file(diffspec.index_to_worktree('file.txt'), repo_root)

    assert.is_nil(lines)
    assert.are.equal('Gdiff does not support mode-only changes', err)
  end)

  it('rejects binary files before treating bytes as text hunks', function()
    local repo_root = create_repo()
    write_binary_file(repo_root .. '/bin.dat', 'binary\\000old')
    git_cmd(repo_root, { 'add', 'bin.dat' })
    git_cmd(repo_root, { 'commit', '-qm', 'binary' })
    write_binary_file(repo_root .. '/bin.dat', 'binary\\000new')

    local lines, err = render.file(diffspec.index_to_worktree('bin.dat'), repo_root)

    assert.is_nil(lines)
    assert.are.equal('Gdiff does not support binary files', err)
  end)

  it('rejects submodule gitlinks before rendering pseudo text hunks', function()
    local repo_root = create_repo()
    git_cmd(repo_root, {
      'update-index',
      '--add',
      '--cacheinfo',
      '160000,0123456789012345678901234567890123456789,submodule',
    })

    local lines, err = render.file(diffspec.head_to_index('submodule'), repo_root)

    assert.is_nil(lines)
    assert.are.equal('Gdiff does not support submodule changes', err)
  end)
end)
