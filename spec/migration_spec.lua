local migration = require('diffs.migration')

describe('migration', function()
  local tmp
  local old_notify_once
  local notifications

  local function system(args)
    local output = vim.fn.system(args)
    assert.are.equal(0, vim.v.shell_error, output)
    return output
  end

  local function git_repo_with_origin(origin)
    local root = tmp .. '/repo'
    vim.fn.mkdir(root, 'p')
    system({ 'git', 'init', '--quiet', root })
    system({ 'git', '-C', root, 'remote', 'add', 'origin', origin })
    return root
  end

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, 'p')
    notifications = {}
    old_notify_once = vim.notify_once
    vim.notify_once = function(message, level)
      table.insert(notifications, { message = message, level = level })
    end
  end)

  after_each(function()
    vim.notify_once = old_notify_once
    vim.fn.delete(tmp, 'rf')
  end)

  it('detects GitHub diffs.nvim remotes', function()
    assert.is_true(migration.is_github_origin('https://github.com/barrettruth/diffs.nvim'))
    assert.is_true(migration.is_github_origin('git@github.com:barrettruth/diffs.nvim.git'))
    assert.is_true(migration.is_github_origin('ssh://git@github.com/barrettruth/diffs.nvim.git'))
  end)

  it('does not match Forgejo or unrelated remotes', function()
    assert.is_false(
      migration.is_github_origin('ssh://git@forge.barrettruth.com/barrettruth/diffs.nvim.git')
    )
    assert.is_false(migration.is_github_origin('https://github.com/other/diffs.nvim'))
    assert.is_false(migration.is_github_origin('https://github.com/barrettruth/other.nvim'))
  end)

  it('warns for GitHub installs', function()
    local root = git_repo_with_origin('https://github.com/barrettruth/diffs.nvim.git')

    assert.is_true(migration.warn_if_github_source(root))

    assert.are.equal(1, #notifications)
    assert.are.equal(vim.log.levels.WARN, notifications[1].level)
    assert.are.equal(
      '[diffs.nvim] This repository will be removed from GitHub on October 31, 2026. '
        .. 'Install from Forgejo: https://forge.barrettruth.com/barrettruth/diffs.nvim. '
        .. 'See :help diffs-migration.',
      notifications[1].message
    )
  end)

  it('does not warn for Forgejo installs', function()
    local root = git_repo_with_origin('ssh://git@forge.barrettruth.com/barrettruth/diffs.nvim.git')

    assert.is_false(migration.warn_if_github_source(root))

    assert.are.equal(0, #notifications)
  end)
end)
