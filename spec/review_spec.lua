require('spec.helpers')

local render = require('diffs.render')
local review = require('diffs.review')

local repo
local saved_diffopt

local function git_result(args, opts)
  local cmd = { 'git', '-C', repo }
  vim.list_extend(cmd, args)
  return vim.system(cmd, vim.tbl_extend('force', { text = true }, opts or {})):wait()
end

local function git(args, opts)
  local result = git_result(args, opts)
  assert.are.equal(0, result.code, result.stderr)
  return vim.trim(result.stdout)
end

local function tree(text)
  local blob = git({ 'hash-object', '-w', '--stdin' }, { stdin = text .. '\n' })
  return git({ 'mktree' }, { stdin = '100644 blob ' .. blob .. '\tfile.txt\n' })
end

local function commit(name, tree_id, parents, timestamp)
  local args = { 'commit-tree', tree_id, '-m', name }
  for _, parent in ipairs(parents) do
    vim.list_extend(args, { '-p', parent })
  end
  local date = tostring(timestamp) .. ' +0000'
  local oid = git(args, { env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date } })
  git({ 'update-ref', 'refs/heads/' .. name, oid })
  return oid
end

local function raw_diff(expression)
  return git_result({
    'diff',
    '--no-ext-diff',
    '--no-color',
    '--src-prefix=a/',
    '--dst-prefix=b/',
    '--end-of-options',
    expression,
    '--',
  })
end

local function run_review(expression)
  local spec, parse_err = review.parse_arg(expression)
  assert.is_nil(parse_err)
  local normalized, normalize_err = review.normalize(spec, repo)
  assert.is_nil(normalize_err)
  local lines, err = review.run(normalized, {
    replace_combined_diffs = function(result)
      return result
    end,
  })
  return lines, err, spec
end

describe('review Git revisions', function()
  before_each(function()
    saved_diffopt = vim.o.diffopt
    vim.o.diffopt = 'internal,filler'
    repo = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(repo, 'p')
    git({ 'init', '-q', '-b', 'main' })
    git({ 'config', 'user.email', 'test@example.com' })
    git({ 'config', 'user.name', 'Test' })
    git({ 'config', 'commit.gpgsign', 'false' })
    local base = commit('base', tree('base'), {}, 1000000000)
    commit('main', tree('main'), { base }, 1000000200)
    commit('feature', tree('feature'), { base }, 1000000100)
  end)

  after_each(function()
    vim.o.diffopt = saved_diffopt
    vim.fn.delete(repo, 'rf')
  end)

  for _, expression in ipairs({
    'main..feature',
    'main...feature',
    '..feature',
    'feature..',
    '...feature',
    'feature...',
  }) do
    it('uses Git output for ' .. expression, function()
      local expected = raw_diff(expression)
      assert.are.equal(0, expected.code, expected.stderr)
      local lines, err = run_review(expression)
      assert.is_nil(err)
      assert.are.equal(expected.stdout, table.concat(lines, '\n') .. '\n')
    end)
  end

  it('accepts annotated tags and refs that are also filenames', function()
    git({ '-c', 'tag.gpgsign=false', 'tag', '-a', 'release', 'main', '-m', 'release' })
    vim.fn.writefile({ 'path named main' }, repo .. '/main')
    for _, expression in ipairs({ 'release..feature', 'main..feature' }) do
      local expected = raw_diff(expression)
      local lines, err = run_review(expression)
      assert.is_nil(err)
      assert.are.equal(expected.stdout, table.concat(lines, '\n') .. '\n')
    end
  end)

  it('returns the Git error for a missing revision', function()
    local expected = raw_diff('main..missing')
    assert.are_not.equal(0, expected.code)
    local lines, err = run_review('main..missing')
    assert.is_nil(lines)
    assert.are.equal(vim.trim(expected.stderr), err)
  end)

  it('keeps all current-state sections for a single base or the default branch', function()
    git({ 'checkout', '-f', 'main' })
    vim.fn.writefile({ 'staged' }, repo .. '/file.txt')
    git({ 'add', 'file.txt' })
    vim.fn.writefile({ 'working' }, repo .. '/file.txt')
    vim.fn.writefile({ 'untracked' }, repo .. '/new.txt')
    git({ 'update-ref', 'refs/remotes/origin/main', git({ 'rev-parse', 'base' }) })
    git({ 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main' })

    for _, spec in ipairs({ { base = 'base' }, {} }) do
      local normalized, err = review.normalize(spec, repo)
      assert.is_nil(err)
      assert.is_nil(normalized.target)
      local lines, render_err, metadata = review.render(normalized, {
        replace_combined_diffs = function(result)
          return result
        end,
      })
      assert.is_nil(render_err)
      assert.are.same(
        { 'branch', 'staged', 'unstaged', 'untracked' },
        vim.tbl_map(function(section)
          return section.id
        end, metadata.sections)
      )
      for _, text in ipairs({ '+main', '+staged', '+working', '+untracked' }) do
        assert.is_true(vim.tbl_contains(lines, text), text)
      end
    end
  end)

  it('uses the same merge base for the review and split content', function()
    local base = git({ 'rev-parse', 'base' })
    local main_tree = git({ 'rev-parse', 'main^{tree}' })
    local feature_tree = git({ 'rev-parse', 'feature^{tree}' })
    local left = git({ 'rev-parse', 'main' })
    local chain = commit('chain1', feature_tree, { base }, 1000000100)
    chain = commit('chain2', feature_tree, { chain }, 1000000101)
    local right = commit('other', feature_tree, { chain }, 1000000150)
    commit('cross1', main_tree, { left, right }, 1000000300)
    commit('cross2', feature_tree, { right, left }, 1000000400)
    git({ 'commit-graph', 'write', '--reachable' })

    local expected = raw_diff('cross1...cross2')
    assert.are.equal(0, expected.code, expected.stderr)
    assert.is_truthy(expected.stderr:find('multiple merge bases', 1, true))
    local lines, err, spec = run_review('cross1...cross2')
    assert.is_nil(err)
    assert.are.equal(expected.stdout, table.concat(lines, '\n') .. '\n')

    local diff_spec, _, spec_err = review.diff_spec_for_file(spec, repo, 'file.txt')
    assert.is_nil(spec_err)
    local selected_base = expected.stderr:match('using (%x+)')
    assert.are.equal(selected_base, diff_spec.left.rev)
    local old_lines, read_err = render.read_endpoint(diff_spec.left, repo .. '/file.txt')
    assert.is_nil(read_err)
    assert.are.equal(git({ 'show', selected_base .. ':file.txt' }), table.concat(old_lines, '\n'))
  end)
end)
