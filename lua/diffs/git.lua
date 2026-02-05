local M = {}

---@param filepath string
---@return string?
function M.get_repo_root(filepath)
  local dir = vim.fn.fnamemodify(filepath, ':h')
  local result = vim.fn.systemlist({ 'git', '-C', dir, 'rev-parse', '--show-toplevel' })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return result[1]
end

---@param revision string
---@param filepath string
---@return string[]?, string?
function M.get_file_content(revision, filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return nil, 'not in a git repository'
  end

  local rel_path = vim.fn.fnamemodify(filepath, ':.')
  if vim.startswith(filepath, repo_root) then
    rel_path = filepath:sub(#repo_root + 2)
  end

  local result = vim.fn.systemlist({ 'git', '-C', repo_root, 'show', revision .. ':' .. rel_path })
  if vim.v.shell_error ~= 0 then
    return nil, 'failed to get file at revision: ' .. revision
  end
  return result, nil
end

---@param filepath string
---@return string?
function M.get_relative_path(filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return nil
  end
  if vim.startswith(filepath, repo_root) then
    return filepath:sub(#repo_root + 2)
  end
  return vim.fn.fnamemodify(filepath, ':.')
end

---@param filepath string
---@return string[]?, string?
function M.get_index_content(filepath)
  local repo_root = M.get_repo_root(filepath)
  if not repo_root then
    return nil, 'not in a git repository'
  end

  local rel_path = M.get_relative_path(filepath)
  if not rel_path then
    return nil, 'could not determine relative path'
  end

  local result = vim.fn.systemlist({ 'git', '-C', repo_root, 'show', ':0:' .. rel_path })
  if vim.v.shell_error ~= 0 then
    return nil, 'file not in index'
  end
  return result, nil
end

---@param filepath string
---@return string[]?, string?
function M.get_working_content(filepath)
  if vim.fn.filereadable(filepath) ~= 1 then
    return nil, 'file not readable'
  end
  local lines = vim.fn.readfile(filepath)
  return lines, nil
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

  vim.fn.system({ 'git', '-C', repo_root, 'ls-files', '--stage', '--', rel_path })
  return vim.v.shell_error == 0
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

return M
