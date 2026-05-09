require('spec.helpers')
local git = require('diffs.git')

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

describe('git', function()
  after_each(function()
    for _, repo_root in ipairs(test_repos) do
      vim.fn.delete(repo_root, 'rf')
    end
    test_repos = {}
  end)

  describe('get_repo_root', function()
    it('returns repo root for current repo', function()
      local cwd = vim.fn.getcwd()
      local root = git.get_repo_root(cwd .. '/lua/diffs/init.lua')
      assert.is_not_nil(root)
      assert.are.equal(cwd, root)
    end)

    it('returns nil for non-git directory', function()
      local root = git.get_repo_root('/tmp')
      assert.is_nil(root)
    end)
  end)

  describe('get_file_content', function()
    it('returns file content at HEAD', function()
      local cwd = vim.fn.getcwd()
      local content, err = git.get_file_content('HEAD', cwd .. '/lua/diffs/init.lua')
      assert.is_nil(err)
      assert.is_not_nil(content)
      assert.is_true(#content > 0)
    end)

    it('returns error for non-existent file', function()
      local cwd = vim.fn.getcwd()
      local content, err = git.get_file_content('HEAD', cwd .. '/does_not_exist.lua')
      assert.is_nil(content)
      assert.is_not_nil(err)
    end)

    it('returns error for non-git directory', function()
      local content, err = git.get_file_content('HEAD', '/tmp/some_file.txt')
      assert.is_nil(content)
      assert.is_not_nil(err)
    end)
  end)

  describe('get_relative_path', function()
    it('returns relative path within repo', function()
      local cwd = vim.fn.getcwd()
      local rel = git.get_relative_path(cwd .. '/lua/diffs/init.lua')
      assert.are.equal('lua/diffs/init.lua', rel)
    end)

    it('returns nil for non-git directory', function()
      local rel = git.get_relative_path('/tmp/some_file.txt')
      assert.is_nil(rel)
    end)
  end)

  describe('is_unmerged', function()
    it('detects paths with unmerged index stages', function()
      local repo_root = create_repo()
      local filepath = repo_root .. '/file.txt'

      git_cmd(repo_root, { 'checkout', '-qb', 'ours' })
      vim.fn.writefile({ 'line 1', 'line 2 ours' }, filepath)
      git_cmd(repo_root, { 'commit', '-am', 'ours' })
      git_cmd(repo_root, { 'checkout', '-qb', 'theirs', 'HEAD~1' })
      vim.fn.writefile({ 'line 1', 'line 2 theirs' }, filepath)
      git_cmd(repo_root, { 'commit', '-am', 'theirs' })

      local merge_output = vim.fn.systemlist({ 'git', '-C', repo_root, 'merge', 'ours' })
      assert.are_not.equal(0, vim.v.shell_error, table.concat(merge_output, '\n'))

      assert.is_true(git.is_unmerged(filepath))
    end)

    it('returns false outside an unmerged path', function()
      local repo_root = create_repo()

      assert.is_false(git.is_unmerged(repo_root .. '/file.txt'))
      assert.is_false(git.is_unmerged('/tmp/not-a-diffs-repo-file.txt'))
    end)
  end)
end)
