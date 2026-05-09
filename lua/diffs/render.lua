local M = {}

local diffspec = require('diffs.spec')
local git = require('diffs.git')

---@class diffs.RenderFileOpts
---@field worktree_lines? string[]
---@field empty_on_missing? boolean
---@field old_path? string
---@field new_path? string

---@param old_lines string[]
---@param new_lines string[]
---@param old_name string
---@param new_name string
---@return string[]
function M.unified_lines(old_lines, new_lines, old_name, new_name)
  local old_content = table.concat(old_lines, '\n')
  local new_content = table.concat(new_lines, '\n')

  local diff_fn = vim.text and vim.text.diff or vim.diff
  local diff_output = diff_fn(old_content, new_content, {
    result_type = 'unified',
    ctxlen = 3,
  })

  if not diff_output or diff_output == '' then
    return {}
  end

  local diff_lines = vim.split(diff_output, '\n', { plain = true })

  local result = {
    'diff --git a/' .. old_name .. ' b/' .. new_name,
    '--- a/' .. old_name,
    '+++ b/' .. new_name,
  }
  for _, line in ipairs(diff_lines) do
    table.insert(result, line)
  end

  return result
end

---@param repo_root string
---@param path string
---@return string
local function abs_path(repo_root, path)
  return repo_root .. '/' .. path
end

---@param endpoint diffs.Endpoint
---@param filepath string
---@param opts? diffs.RenderFileOpts
---@return string[]?, string?
function M.read_endpoint(endpoint, filepath, opts)
  endpoint = diffspec.endpoint(endpoint)
  opts = opts or {}

  local lines, err
  if endpoint.kind == diffspec.endpoint_kind.tree then
    lines, err = git.get_file_content(endpoint.rev, filepath)
  elseif endpoint.kind == diffspec.endpoint_kind.index then
    lines, err = git.get_index_content(filepath)
  elseif endpoint.kind == diffspec.endpoint_kind.worktree then
    lines = opts.worktree_lines
    if not lines then
      lines, err = git.get_working_content(filepath)
    end
  else
    return nil, 'unsupported endpoint: ' .. tostring(endpoint.kind)
  end

  if not lines and opts.empty_on_missing then
    return {}, nil
  end

  return lines, err
end

---@param diff_spec diffs.DiffSpec
---@param repo_root string
---@param opts? diffs.RenderFileOpts
---@return string[]?, string?
function M.file(diff_spec, repo_root, opts)
  diff_spec = diffspec.new(diff_spec)
  opts = opts or {}

  if diff_spec.scope.kind ~= diffspec.scope_kind.file then
    return nil, 'unsupported DiffSpec scope: ' .. tostring(diff_spec.scope.kind)
  end

  local path = diff_spec.scope.path
  local old_path = opts.old_path or path
  local new_path = opts.new_path or path

  local old_lines, old_err = M.read_endpoint(diff_spec.left, abs_path(repo_root, old_path), opts)
  if not old_lines then
    return nil, old_err or 'could not read left endpoint'
  end

  local new_lines, new_err = M.read_endpoint(diff_spec.right, abs_path(repo_root, new_path), opts)
  if not new_lines then
    return nil, new_err or 'could not read right endpoint'
  end

  return M.unified_lines(old_lines, new_lines, old_path, new_path), nil
end

return M
