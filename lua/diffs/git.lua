local M = {}

local content = require('diffs.content')

local repo_root_cache = {}

local function is_index_stage(revision)
  return type(revision) == 'string' and revision:match('^:%d$') ~= nil
end

---@param filepath? string
---@return string?
function M.get_repo_root(filepath)
  local dir = vim.fn.fnamemodify(filepath, ':h')
  if repo_root_cache[dir] ~= nil then
    return repo_root_cache[dir]
  end
  local result = vim.fn.systemlist({ 'git', '-C', dir, 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  repo_root_cache[dir] = result[1]
  return result[1]
end

---@param repo_root string
---@param filepath string
---@return string?
local function relative_path(repo_root, filepath)
  if vim.startswith(filepath, repo_root) then
    return filepath:sub(#repo_root + 2)
  end
  return vim.fn.fnamemodify(filepath, ':.')
end

---@param revision string
---@param filepath string
---@return diffs.ContentLines?, string?
function M.get_file_content(revision, filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return nil, 'not in a git repository'
  end

  local rel_path = relative_path(repo_root, filepath)

  if not is_index_stage(revision) then
    vim.fn.system({ 'git', '-C', repo_root, 'rev-parse', '--verify', revision .. '^{tree}' })
    if vim.v.shell_error ~= 0 then
      return nil, 'failed to resolve revision: ' .. revision
    end
  end

  local result =
    vim.fn.systemlist({ 'git', '-C', repo_root, 'show', revision .. ':' .. rel_path }, nil, true)
  if vim.v.shell_error ~= 0 then
    return nil, 'file not in revision: ' .. revision
  end
  return content.from_raw_lines(result), nil
end

---@param filepath string
---@return string?
function M.get_relative_path(filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return nil
  end
  return relative_path(repo_root, filepath)
end

---@param filepath string
---@return diffs.ContentLines?, string?
function M.get_index_content(filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return nil, 'not in a git repository'
  end

  local rel_path = M.get_relative_path(filepath)
  if not rel_path then
    return nil, 'could not determine relative path'
  end

  local result = vim.fn.systemlist({ 'git', '-C', repo_root, 'show', ':0:' .. rel_path }, nil, true)
  if vim.v.shell_error ~= 0 then
    return nil, 'file not in index'
  end
  return content.from_raw_lines(result), nil
end

---@param filepath string
---@return diffs.ContentLines?, string?
function M.get_working_content(filepath)
  if vim.fn.filereadable(filepath) ~= 1 then
    return nil, 'file not readable'
  end
  local lines = vim.fn.readfile(filepath, 'b')
  return content.from_raw_lines(lines, { empty_is_empty = vim.fn.getfsize(filepath) == 0 }), nil
end

---@param filepath string
---@return string?
function M.get_index_mode(filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return nil
  end

  local rel_path = M.get_relative_path(filepath)
  if not rel_path then
    return nil
  end

  local result =
    vim.fn.systemlist({ 'git', '-C', repo_root, 'ls-files', '--stage', '--', rel_path })
  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end
  return result[1]:match('^(%d+)')
end

---@param revision string
---@param filepath string
---@return string?
function M.get_tree_mode(revision, filepath)
  if is_index_stage(revision) then
    return nil
  end

  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return nil
  end

  local rel_path = M.get_relative_path(filepath)
  if not rel_path then
    return nil
  end

  local result = vim.fn.systemlist({ 'git', '-C', repo_root, 'ls-tree', revision, '--', rel_path })
  if vim.v.shell_error ~= 0 or #result == 0 then
    return nil
  end
  return result[1]:match('^(%d+)')
end

---@param filepath string
---@return string?
function M.get_working_mode(filepath)
  if vim.fn.filereadable(filepath) ~= 1 then
    return nil
  end

  local perm = vim.fn.getfperm(filepath)
  if perm:sub(3, 3) == 'x' then
    return '100755'
  end
  return '100644'
end

---@param filepath string
---@return boolean
function M.file_exists_in_index(filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return false
  end

  local rel_path = M.get_relative_path(filepath)
  if not rel_path then
    return false
  end

  local result =
    vim.fn.systemlist({ 'git', '-C', repo_root, 'ls-files', '--stage', '--', rel_path })
  return vim.v.shell_error == 0 and #result > 0
end

---@param revision string
---@param filepath string
---@return boolean
function M.file_exists_at_revision(revision, filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return false
  end

  local rel_path = M.get_relative_path(filepath)
  if not rel_path then
    return false
  end

  vim.fn.system({ 'git', '-C', repo_root, 'cat-file', '-e', revision .. ':' .. rel_path })
  return vim.v.shell_error == 0
end

---@class diffs.GitApplyOpts
---@field cached? boolean
---@field reverse? boolean
---@field check? boolean
---@field recount? boolean

---@param repo_root string
---@param patch string
---@param opts? diffs.GitApplyOpts
---@return boolean, string[]
function M.apply_patch(repo_root, patch, opts)
  opts = opts or {}
  local cmd = { 'git', '-C', repo_root, 'apply' }
  if opts.cached then
    table.insert(cmd, '--cached')
  end
  if opts.reverse then
    table.insert(cmd, '--reverse')
  end
  if opts.check then
    table.insert(cmd, '--check')
  end
  if opts.recount then
    table.insert(cmd, '--recount')
  end

  local output = vim.fn.systemlist(cmd, patch)
  return vim.v.shell_error == 0, output
end

return M
