local M = {}

local content = require('diffs.content')
local diffopt = require('diffs.diffopt')
local diffspec = require('diffs.spec')
local git = require('diffs.git')

---@class diffs.RenderFileOpts
---@field worktree_lines? diffs.ContentLines|string[]
---@field empty_on_missing? boolean
---@field old_path? string
---@field new_path? string

---@class diffs.UnifiedLinesOpts
---@field old_missing? boolean
---@field new_missing? boolean
---@field new_mode? string
---@field deleted_mode? string

local missing_errors = {
  ['file not in index'] = true,
  ['file not readable'] = true,
}

---@param err string?
---@return boolean
local function is_missing_error(err)
  return err ~= nil and (missing_errors[err] or err:match('^file not in revision: ') ~= nil)
end

---@param lines string[]?
---@return boolean
function M.has_binary_lines(lines)
  for _, line in ipairs(lines or {}) do
    if line:find('\0', 1, true) then
      return true
    end
  end
  return false
end

---@param old_lines diffs.ContentLines|string[]
---@param new_lines diffs.ContentLines|string[]
---@param old_name string
---@param new_name string
---@param opts? diffs.UnifiedLinesOpts
---@return string[]
function M.unified_lines(old_lines, new_lines, old_name, new_name, opts)
  opts = opts or {}
  local old_content = content.to_string(old_lines)
  local new_content = content.to_string(new_lines)

  local diff_fn = vim.text and vim.text.diff or vim.diff
  local diff_output = diff_fn(
    old_content,
    new_content,
    vim.tbl_extend('force', {
      result_type = 'unified',
      ctxlen = 3,
    }, diffopt.vim_diff_opts())
  )

  if not diff_output or diff_output == '' then
    return {}
  end

  local diff_lines = vim.split(diff_output, '\n', { plain = true })

  local result = {
    'diff --git a/' .. old_name .. ' b/' .. new_name,
  }

  if opts.old_missing then
    result[#result + 1] = 'new file mode ' .. (opts.new_mode or '100644')
    result[#result + 1] = '--- /dev/null'
  else
    result[#result + 1] = '--- a/' .. old_name
  end

  if opts.new_missing then
    if not opts.old_missing then
      table.insert(result, 2, 'deleted file mode ' .. (opts.deleted_mode or '100644'))
    end
    result[#result + 1] = '+++ /dev/null'
  else
    result[#result + 1] = '+++ b/' .. new_name
  end

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
---@return string?
local function file_mode(endpoint, filepath)
  endpoint = diffspec.endpoint(endpoint)

  if endpoint.kind == diffspec.endpoint_kind.tree then
    return git.get_tree_mode(endpoint.rev, filepath)
  end

  if endpoint.kind == diffspec.endpoint_kind.index then
    return git.get_index_mode(filepath)
  end

  if endpoint.kind == diffspec.endpoint_kind.worktree then
    return git.get_working_mode(filepath)
  end

  return nil
end

---@param endpoint diffs.Endpoint
---@param filepath string
---@param opts? diffs.RenderFileOpts
---@return diffs.ContentLines|string[]?, string?, boolean
function M.read_endpoint(endpoint, filepath, opts)
  endpoint = diffspec.endpoint(endpoint)
  opts = opts or {}

  local lines, err
  if endpoint.kind == diffspec.endpoint_kind.tree then
    lines, err = git.get_file_content(endpoint.rev, filepath)
  elseif endpoint.kind == diffspec.endpoint_kind.stage then
    lines, err = git.get_file_content(':' .. endpoint.stage, filepath)
  elseif endpoint.kind == diffspec.endpoint_kind.index then
    lines, err = git.get_index_content(filepath)
  elseif endpoint.kind == diffspec.endpoint_kind.worktree then
    lines = opts.worktree_lines
    if not lines then
      lines, err = git.get_working_content(filepath)
    end
  else
    return nil, 'unsupported endpoint: ' .. tostring(endpoint.kind), false
  end

  if not lines and opts.empty_on_missing and is_missing_error(err) then
    return {}, nil, true
  end

  return lines, err, false
end

---@param diff_spec diffs.DiffSpec
---@param repo_root string
---@param args string[]
---@return string[]?
local function build_git_diff_cmd(diff_spec, repo_root, args)
  local cmd = { 'git', '-C', repo_root, 'diff', '--no-ext-diff', '--no-color' }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  local left = diff_spec.left
  local right = diff_spec.right

  if
    left.kind == diffspec.endpoint_kind.index and right.kind == diffspec.endpoint_kind.worktree
  then
    return cmd
  end

  if left.kind == diffspec.endpoint_kind.tree and right.kind == diffspec.endpoint_kind.index then
    table.insert(cmd, '--cached')
    table.insert(cmd, left.rev)
    return cmd
  end

  if left.kind == diffspec.endpoint_kind.tree and right.kind == diffspec.endpoint_kind.worktree then
    table.insert(cmd, left.rev)
    return cmd
  end

  if left.kind == diffspec.endpoint_kind.tree and right.kind == diffspec.endpoint_kind.tree then
    table.insert(cmd, left.rev)
    table.insert(cmd, right.rev)
    return cmd
  end

  return nil
end

---@param diff_spec diffs.DiffSpec
---@param repo_root string
---@param path string
---@param flag string
---@return string[]
local function git_diff_lines(diff_spec, repo_root, path, flag)
  local cmd = build_git_diff_cmd(diff_spec, repo_root, { flag })
  if not cmd then
    return {}
  end

  table.insert(cmd, '--')
  table.insert(cmd, path)
  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return result
end

---@param diff_spec diffs.DiffSpec
---@param repo_root string
---@param path string
---@return boolean
local function has_raw_changes(diff_spec, repo_root, path)
  return #git_diff_lines(diff_spec, repo_root, path, '--raw') > 0
end

---@param diff_spec diffs.DiffSpec
---@param repo_root string
---@param path string
---@return boolean
local function has_binary_changes(diff_spec, repo_root, path)
  for _, line in ipairs(git_diff_lines(diff_spec, repo_root, path, '--numstat')) do
    if line:match('^%-%s+%-%s+') then
      return true
    end
  end
  return false
end

---@param diff_spec diffs.DiffSpec
---@param repo_root string
---@param path string
---@return boolean
local function has_renamed_or_copied_path(diff_spec, repo_root, path)
  local cmd = build_git_diff_cmd(diff_spec, repo_root, { '--name-status', '-M', '-C' })
  if not cmd then
    return false
  end

  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return false
  end

  for _, line in ipairs(result) do
    local status = line:match('^([RC]%d*)%s')
    if status then
      local fields = vim.split(line, '\t', { plain = true })
      for i = 2, #fields do
        if fields[i] == path then
          return true
        end
      end
    end
  end

  return false
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
  local old_filepath = abs_path(repo_root, old_path)
  local new_filepath = abs_path(repo_root, new_path)

  local old_mode = file_mode(diff_spec.left, old_filepath)
  local new_mode = file_mode(diff_spec.right, new_filepath)
  if old_mode == '160000' or new_mode == '160000' then
    return nil, 'diff does not support submodule changes'
  end

  if has_renamed_or_copied_path(diff_spec, repo_root, path) then
    return nil, 'diff does not support rename or copy changes'
  end

  if has_binary_changes(diff_spec, repo_root, path) then
    return nil, 'diff does not support binary files'
  end

  local old_lines, old_err, old_missing = M.read_endpoint(diff_spec.left, old_filepath, {
    worktree_lines = opts.worktree_lines,
    empty_on_missing = true,
  })
  if not old_lines then
    return nil, old_err or 'could not read left endpoint'
  end

  local new_lines, new_err, new_missing = M.read_endpoint(diff_spec.right, new_filepath, {
    worktree_lines = opts.worktree_lines,
    empty_on_missing = true,
  })
  if not new_lines then
    return nil, new_err or 'could not read right endpoint'
  end

  if M.has_binary_lines(old_lines) or M.has_binary_lines(new_lines) then
    return nil, 'diff does not support binary files'
  end

  local diff_lines = M.unified_lines(old_lines, new_lines, old_path, new_path, {
    old_missing = old_missing,
    new_missing = new_missing,
    new_mode = new_mode,
    deleted_mode = old_mode,
  })
  if
    #diff_lines == 0
    and old_mode
    and new_mode
    and old_mode ~= new_mode
    and has_raw_changes(diff_spec, repo_root, path)
  then
    return nil, 'diff does not support mode-only changes'
  end

  return diff_lines, nil
end

return M
