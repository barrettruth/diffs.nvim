local M = {}

local diffspec = require('diffs.spec')
local git = require('diffs.git')
local lists = require('diffs.lists')
local log = require('diffs.log')

local dbg = log.dbg
local notify = log.notify

---@class diffs.GreviewSpec
---@field base? string
---@field target? string
---@field repo? string
---@field mode? string
---@field vertical? boolean

---@class diffs.NormalizedGreview
---@field base string
---@field target string?
---@field repo_root string
---@field mode string?
---@field vertical boolean
---@field display string
---@field exec_args string[]

---@class diffs.ReviewDeps
---@field create_generated_diff_buffer fun(opts: diffs.GeneratedDiffBufferOpts): integer
---@field show_generated_diff_buffer fun(bufnr: integer, vertical?: boolean)
---@field attach_generated_diff_buffer fun(bufnr: integer)
---@field replace_combined_diffs fun(lines: string[], repo_root: string): string[]

---@param bufnr integer
---@param name string
---@return any
local function get_buf_var(bufnr, name)
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  if ok then
    return value
  end
  return nil
end

---@param repo? string
---@return string?
local function resolve_repo_root(repo)
  if repo and repo ~= '' then
    return git.get_repo_root(repo .. '/.')
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local repo_root = git.get_repo_root(filepath ~= '' and filepath or nil)
  if repo_root then
    return repo_root
  end

  local cwd = vim.fn.getcwd()
  return git.get_repo_root(cwd .. '/.')
end

---@param repo_root string
---@return string?
local function default_branch(repo_root)
  local ref =
    vim.fn.systemlist({ 'git', '-C', repo_root, 'symbolic-ref', 'refs/remotes/origin/HEAD' })
  if vim.v.shell_error ~= 0 or not ref[1] or ref[1] == '' then
    return nil
  end
  return ref[1]:gsub('^refs/remotes/', '')
end

---@param repo_root string
---@param args string[]
---@return boolean
local function git_exits_zero(repo_root, args)
  local cmd = { 'git', '-C', repo_root }
  vim.list_extend(cmd, args)
  vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0
end

---@param repo_root string
---@param ref string
---@return boolean
local function ref_exists(repo_root, ref)
  return git_exits_zero(repo_root, { 'rev-parse', '--verify', '--quiet', ref .. '^{commit}' })
end

---@param repo_root string
---@param base string
---@param target string
---@return boolean
local function merge_base_exists(repo_root, base, target)
  return git_exits_zero(repo_root, { 'merge-base', base, target })
end

---@param repo_root string
---@param base string
---@param target string
---@return string?, string?
local function merge_base(repo_root, base, target)
  local result = vim.fn.systemlist({ 'git', '-C', repo_root, 'merge-base', base, target })
  if vim.v.shell_error ~= 0 or not result[1] or result[1] == '' then
    return nil, 'Greview merge base not found for spec: ' .. base .. '...' .. target
  end
  return result[1], nil
end

---@param repo_root string
---@param base string
---@param target string?
---@param mode string?
---@param display string
---@return string?
local function validate_refs(repo_root, base, target, mode, display)
  if not ref_exists(repo_root, base) then
    return ('Greview base ref not found: %s (spec: %s)'):format(base, display)
  end

  if target and not ref_exists(repo_root, target) then
    return ('Greview target ref not found: %s (spec: %s)'):format(target, display)
  end

  if target and mode == 'merge-base' and not merge_base_exists(repo_root, base, target) then
    return 'Greview merge base not found for spec: ' .. display
  end

  return nil
end

---@param arg? string
---@return diffs.GreviewSpec?, string?
function M.parse_arg(arg)
  if not arg or arg == '' then
    return {}, nil
  end

  local base, target = arg:match('^(.-)%.%.%.(.+)$')
  if base then
    if base == '' or target == '' then
      return nil, 'invalid review spec'
    end
    return { base = base, target = target, mode = 'merge-base' }, nil
  end

  base, target = arg:match('^(.-)%.%.(.+)$')
  if base then
    if base == '' or target == '' then
      return nil, 'invalid review spec'
    end
    return { base = base, target = target, mode = 'direct' }, nil
  end

  return { base = arg }, nil
end

---@param spec? diffs.GreviewSpec
---@param repo_root_override? string
---@return diffs.NormalizedGreview?, string?
function M.normalize(spec, repo_root_override)
  spec = spec or {}
  if type(spec) ~= 'table' then
    error('diffs: greview() expects a table spec')
  end
  if spec.base ~= nil and type(spec.base) ~= 'string' then
    error('diffs: greview.base must be a string')
  end
  if spec.target ~= nil and type(spec.target) ~= 'string' then
    error('diffs: greview.target must be a string')
  end
  if spec.repo ~= nil and type(spec.repo) ~= 'string' then
    error('diffs: greview.repo must be a string')
  end
  if spec.mode ~= nil and type(spec.mode) ~= 'string' then
    error('diffs: greview.mode must be a string')
  end
  if spec.vertical ~= nil and type(spec.vertical) ~= 'boolean' then
    error('diffs: greview.vertical must be a boolean')
  end

  local repo_root = repo_root_override or resolve_repo_root(spec.repo)
  if not repo_root then
    return nil, 'not in a git repository'
  end

  local base = spec.base
  if not base or base == '' then
    base = default_branch(repo_root)
    if not base then
      return nil, 'cannot detect default branch (try: git remote set-head origin -a)'
    end
  end

  local target = spec.target
  if target == '' then
    error('diffs: greview.target must be a non-empty string')
  end

  local mode = spec.mode
  if target then
    if mode == nil then
      mode = 'merge-base'
    elseif mode ~= 'merge-base' and mode ~= 'direct' then
      error('diffs: greview.mode must be "merge-base" or "direct"')
    end
  elseif mode ~= nil then
    error('diffs: greview.mode requires greview.target')
  end

  local display = base
  local exec_args = { base }
  if target then
    if mode == 'merge-base' then
      display = base .. '...' .. target
      exec_args = { '--merge-base', base, target }
    else
      display = base .. '..' .. target
      exec_args = { base, target }
    end
  end

  local ref_err = validate_refs(repo_root, base, target, mode, display)
  if ref_err then
    return nil, ref_err
  end

  return {
    base = base,
    target = target,
    repo_root = repo_root,
    mode = mode,
    vertical = spec.vertical or false,
    display = display,
    exec_args = exec_args,
  },
    nil
end

---@param review diffs.NormalizedGreview
---@return string[]
function M.build_cmd(review)
  local cmd = { 'git', '-C', review.repo_root, 'diff', '--no-ext-diff', '--no-color' }
  vim.list_extend(cmd, review.exec_args)
  return cmd
end

---@param review_spec diffs.GreviewSpec?
---@param repo_root string
---@param path string
---@return diffs.DiffSpec?, diffs.NormalizedGreview?, string?
function M.diff_spec_for_file(review_spec, repo_root, path)
  if type(path) ~= 'string' or path == '' then
    return nil, nil, 'missing review file path'
  end

  local normalized, normalize_err = M.normalize(review_spec, repo_root)
  if not normalized then
    return nil, nil, normalize_err
  end

  if not normalized.target then
    return diffspec.rev_to_worktree(normalized.base, path), normalized, nil
  end

  if normalized.mode == 'merge-base' then
    local base_rev, merge_err = merge_base(normalized.repo_root, normalized.base, normalized.target)
    if not base_rev then
      return nil, normalized, merge_err
    end
    return diffspec.rev_to_rev(base_rev, normalized.target, path), normalized, nil
  end

  return diffspec.rev_to_rev(normalized.base, normalized.target, path), normalized, nil
end

---@param review diffs.NormalizedGreview
---@return string
function M.buffer_name(review)
  return 'diffs://review:' .. review.display
end

---@param repo_root? string
---@return string[]
local function list_refs(repo_root)
  local cmd = { 'git' }
  if repo_root then
    table.insert(cmd, '-C')
    table.insert(cmd, repo_root)
  end
  vim.list_extend(cmd, {
    'for-each-ref',
    '--format=%(refname:short)',
    'refs/heads/',
    'refs/remotes/',
    'refs/tags/',
  })
  local refs = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return refs
end

---@param arglead string
---@return string[]
function M.complete(arglead)
  local refs = list_refs(resolve_repo_root(nil))
  if arglead == '' then
    return refs
  end

  local base, tail = arglead:match('^(.-)%.%.%.(.*)$')
  if base then
    if base == '' then
      return {}
    end
    local matches = {}
    for _, ref in ipairs(refs) do
      if ref:find(tail, 1, true) == 1 then
        table.insert(matches, base .. '...' .. ref)
      end
    end
    return matches
  end

  base, tail = arglead:match('^(.-)%.%.(.*)$')
  if base then
    if base == '' then
      return {}
    end
    local matches = {}
    for _, ref in ipairs(refs) do
      if ref:find(tail, 1, true) == 1 then
        table.insert(matches, base .. '..' .. ref)
      end
    end
    return matches
  end

  local matches = {}
  for _, ref in ipairs(refs) do
    if ref:find(arglead, 1, true) == 1 then
      table.insert(matches, ref)
    end
  end
  return matches
end

---@param review diffs.NormalizedGreview
---@param deps diffs.ReviewDeps
---@return string[]?, string?
function M.run(review, deps)
  local result = vim.fn.systemlist(M.build_cmd(review))
  if vim.v.shell_error ~= 0 then
    return nil, 'git diff failed for Greview spec: ' .. review.display
  end
  return deps.replace_combined_diffs(result, review.repo_root), nil
end

---@param spec? diffs.GreviewSpec
---@param deps diffs.ReviewDeps
---@return integer?
function M.greview(spec, deps)
  local review, err = M.normalize(spec)
  if not review then
    notify(err, vim.log.levels.ERROR)
    return nil
  end

  local target_name = M.buffer_name(review)
  local existing_buf = vim.fn.bufnr(target_name)
  if existing_buf ~= -1 then
    pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
  end

  local result, diff_err = M.run(review, deps)
  if not result then
    notify(diff_err, vim.log.levels.ERROR)
    return nil
  end
  if #result == 0 then
    notify('no diff against ' .. review.display, vim.log.levels.INFO)
    return nil
  end

  local diff_buf = deps.create_generated_diff_buffer({
    name = target_name,
    lines = result,
    repo_root = review.repo_root,
    source = {
      version = 1,
      kind = 'review',
      repo_root = review.repo_root,
      review = {
        base = review.base,
        target = review.target,
        mode = review.mode,
      },
    },
    vars = {
      diffs_review_base = review.base,
      diffs_review_target = review.target,
      diffs_review_mode = review.mode,
    },
  })

  deps.show_generated_diff_buffer(diff_buf, review.vertical)
  lists.set_for_unified_buffer(diff_buf, result, {
    title = 'review: ' .. review.display,
    loclist_title = 'review hunks: ' .. review.display,
  })

  deps.attach_generated_diff_buffer(diff_buf)
  dbg('opened review buffer %d (%s)', diff_buf, review.display)

  return diff_buf
end

---@param buf integer
---@param lnum integer
---@return string?
function M.file_at_line(buf, lnum)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
  for i = #lines, 1, -1 do
    local file = lines[i]:match('^diff %-%-git a/.+ b/(.+)$')
    if file then
      return file
    end
  end
  return nil
end

---@param review_spec diffs.GreviewSpec?
---@param repo_root string
---@param deps diffs.ReviewDeps
---@return string[]?, string?
local function reload_spec(review_spec, repo_root, deps)
  local normalized, normalize_err = M.normalize(review_spec, repo_root)
  if not normalized then
    return nil, normalize_err
  end

  return M.run(normalized, deps)
end

---@param source diffs.GeneratedBufferSource
---@param deps diffs.ReviewDeps
---@return string[]?, string?
function M.reload_source(source, deps)
  return reload_spec(source.review, source.repo_root, deps)
end

---@param bufnr integer
---@param repo_root string
---@param path string
---@param deps diffs.ReviewDeps
---@return string[]?, string?
function M.reload(bufnr, repo_root, path, deps)
  local stored_base = get_buf_var(bufnr, 'diffs_review_base')
  local stored_target = get_buf_var(bufnr, 'diffs_review_target')
  local stored_mode = get_buf_var(bufnr, 'diffs_review_mode')

  local review_spec
  if stored_base then
    review_spec = {
      base = stored_base,
      target = stored_target,
      mode = stored_mode,
    }
  else
    local parse_err
    review_spec, parse_err = M.parse_arg(path)
    if not review_spec then
      return nil, parse_err
    end
  end

  return reload_spec(review_spec, repo_root, deps)
end

return M
