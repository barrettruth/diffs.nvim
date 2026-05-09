local M = {}

local diffspec = require('diffs.spec')
local git = require('diffs.git')
local hunk_model = require('diffs.hunks')

local endpoint_kind = diffspec.endpoint_kind

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

---@param bufnr integer
---@return diffs.GdiffHunk[]
local function buffer_hunks(bufnr)
  local hunks = get_buf_var(bufnr, 'diffs_hunks')
  if type(hunks) == 'table' then
    return hunks
  end
  return {}
end

---@param bufnr integer
---@return diffs.GdiffHunk?
local function hunk_under_cursor(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  return hunk_model.hunk_at_line(buffer_hunks(bufnr), cursor_line)
end

---@param hunk diffs.GdiffHunk
---@return diffs.DiffSpec?
local function hunk_diff_spec(hunk)
  if not hunk.diff_spec then
    return nil
  end
  local ok, spec = pcall(diffspec.new, hunk.diff_spec)
  if ok then
    return spec
  end
  return nil
end

---@param spec diffs.DiffSpec
---@return boolean
local function is_index_to_worktree(spec)
  return spec.left.kind == endpoint_kind.index and spec.right.kind == endpoint_kind.worktree
end

---@param spec diffs.DiffSpec
---@return boolean
local function is_tree_to_index(spec)
  return spec.left.kind == endpoint_kind.tree and spec.right.kind == endpoint_kind.index
end

---@param lines string[]
local function extend_patch_lines(patch, lines)
  for _, line in ipairs(lines or {}) do
    patch[#patch + 1] = line
  end
end

---@param hunk diffs.GdiffHunk
---@return string?, string?
function M.patch_for_hunk(hunk)
  if not hunk then
    return nil, 'no Gdiff hunk under cursor'
  end
  if type(hunk.file_header_lines) ~= 'table' or #hunk.file_header_lines == 0 then
    return nil, 'cannot build hunk patch without file headers'
  end

  local patch_lines = {}
  extend_patch_lines(patch_lines, hunk.file_header_lines)
  for _, line in ipairs(hunk.lines or {}) do
    patch_lines[#patch_lines + 1] = line.text
  end

  return table.concat(patch_lines, '\n') .. '\n', nil
end

---@param output string[]?
---@return string
local function format_git_output(output)
  local message = table.concat(output or {}, '\n')
  if message == '' then
    return 'git apply failed'
  end
  return message
end

---@param repo_root string
---@param patch string
---@param operation "stage"|"unstage"
---@return boolean, string?
local function checked_apply(repo_root, patch, operation)
  local reverse = operation == 'unstage'
  local ok, output = git.apply_patch(repo_root, patch, {
    cached = true,
    reverse = reverse,
    check = true,
  })
  if not ok then
    return false, format_git_output(output)
  end

  ok, output = git.apply_patch(repo_root, patch, {
    cached = true,
    reverse = reverse,
  })
  if not ok then
    return false, format_git_output(output)
  end

  return true, nil
end

---@param bufnr integer
---@return diffs.GdiffHunk?, diffs.DiffSpec?, string?
local function current_action_context(bufnr)
  local hunk = hunk_under_cursor(bufnr)
  if not hunk then
    return nil, nil, 'no Gdiff hunk under cursor'
  end

  local spec = hunk_diff_spec(hunk)
  if not spec then
    return nil, nil, 'cannot resolve Gdiff hunk edge'
  end

  return hunk, spec, nil
end

---@param message string
---@param level integer
local function notify(message, level)
  vim.notify('[diffs.nvim]: ' .. message, level)
end

---@param bufnr integer
---@param hunk diffs.GdiffHunk
---@param operation "stage"|"unstage"
---@return boolean
local function mutate_hunk(bufnr, hunk, operation)
  local repo_root = get_buf_var(bufnr, 'diffs_repo_root')
  if not repo_root then
    notify('cannot mutate Gdiff hunk without diffs_repo_root', vim.log.levels.ERROR)
    return false
  end

  local patch, patch_err = M.patch_for_hunk(hunk)
  if not patch then
    notify(patch_err or 'cannot build hunk patch', vim.log.levels.ERROR)
    return false
  end

  local ok, err = checked_apply(repo_root, patch, operation)
  if not ok then
    notify('failed to ' .. operation .. ' Gdiff hunk: ' .. err, vim.log.levels.ERROR)
    return false
  end

  return true
end

---@param bufnr integer
---@return boolean
function M.put_hunk(bufnr)
  local hunk, spec, err = current_action_context(bufnr)
  if err then
    notify(err, vim.log.levels.WARN)
    return false
  end
  if not hunk or not spec then
    notify('cannot resolve Gdiff hunk edge', vim.log.levels.WARN)
    return false
  end

  if is_index_to_worktree(spec) then
    return mutate_hunk(bufnr, hunk, 'stage')
  end

  if is_tree_to_index(spec) then
    notify('Gdiff hunk is already in the index', vim.log.levels.WARN)
    return false
  end

  notify('cannot put read-only Gdiff hunk', vim.log.levels.WARN)
  return false
end

---@param bufnr integer
---@return boolean
function M.obtain_hunk(bufnr)
  local hunk, spec, err = current_action_context(bufnr)
  if err then
    notify(err, vim.log.levels.WARN)
    return false
  end
  if not hunk or not spec then
    notify('cannot resolve Gdiff hunk edge', vim.log.levels.WARN)
    return false
  end

  if is_tree_to_index(spec) then
    return mutate_hunk(bufnr, hunk, 'unstage')
  end

  if is_index_to_worktree(spec) then
    notify('restoring worktree hunks is not supported', vim.log.levels.WARN)
    return false
  end

  notify('cannot obtain read-only Gdiff hunk', vim.log.levels.WARN)
  return false
end

return M
