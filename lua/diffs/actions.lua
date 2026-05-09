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

---@param line diffs.GdiffHunkLine
---@return boolean
local function is_change_line(line)
  return line.kind == 'add' or line.kind == 'delete'
end

---@param line diffs.GdiffHunkLine
---@return string
local function context_text(line)
  return ' ' .. line.text:sub(2)
end

---@param lnum integer
---@param range_start integer
---@param range_finish integer
---@return boolean
local function in_range(lnum, range_start, range_finish)
  return lnum >= range_start and lnum <= range_finish
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

---@class diffs.GdiffChangeGroup
---@field lines diffs.GdiffHunkLine[]
---@field has_add boolean
---@field has_delete boolean

---@param hunk diffs.GdiffHunk
---@return diffs.GdiffChangeGroup[]
local function change_groups(hunk)
  local groups = {}
  local current = nil

  local function finish_group()
    if current then
      groups[#groups + 1] = current
      current = nil
    end
  end

  for _, line in ipairs(hunk.lines or {}) do
    if is_change_line(line) then
      current = current or { lines = {}, has_add = false, has_delete = false }
      current.lines[#current.lines + 1] = line
      current.has_add = current.has_add or line.kind == 'add'
      current.has_delete = current.has_delete or line.kind == 'delete'
    elseif line.kind ~= 'meta' then
      finish_group()
    end
  end

  finish_group()
  return groups
end

---@param hunk diffs.GdiffHunk
---@param range_start integer
---@param range_finish integer
---@return string?
local function validate_range(hunk, range_start, range_finish)
  for _, group in ipairs(change_groups(hunk)) do
    if group.has_add and group.has_delete then
      local selected = 0
      for _, line in ipairs(group.lines) do
        if in_range(line.lnum, range_start, range_finish) then
          selected = selected + 1
        end
      end
      if selected > 0 and selected < #group.lines then
        return 'select the complete replacement group before applying it'
      end
    end
  end
  return nil
end

---@param hunk diffs.GdiffHunk
---@param range_start integer
---@param range_finish integer
---@param opts? { target?: "left"|"right" }
---@return string?, string?
function M.patch_for_range(hunk, range_start, range_finish, opts)
  opts = opts or {}
  local target = opts.target or 'left'
  if not hunk then
    return nil, 'no Gdiff hunk under cursor'
  end
  if target ~= 'left' and target ~= 'right' then
    return nil, 'invalid Gdiff range patch target'
  end
  if type(range_start) ~= 'number' or type(range_finish) ~= 'number' then
    return nil, 'invalid Gdiff visual range'
  end
  if range_finish < range_start then
    range_start, range_finish = range_finish, range_start
  end
  if range_start < hunk.buffer_range.start or range_finish > hunk.buffer_range.finish then
    return nil, 'visual selection must stay within one Gdiff hunk'
  end

  local range_err = validate_range(hunk, range_start, range_finish)
  if range_err then
    return nil, range_err
  end
  if type(hunk.file_header_lines) ~= 'table' or #hunk.file_header_lines == 0 then
    return nil, 'cannot build hunk patch without file headers'
  end

  local patch_lines = {}
  local has_change = false
  local previous_emitted_change = false
  extend_patch_lines(patch_lines, hunk.file_header_lines)
  patch_lines[#patch_lines + 1] = hunk.header

  for _, line in ipairs(hunk.lines or {}) do
    local emitted = nil
    local emitted_change = false
    if line.kind == 'context' or (line.kind == 'meta' and previous_emitted_change) then
      emitted = line.text
    elseif line.kind == 'add' then
      if in_range(line.lnum, range_start, range_finish) then
        emitted = line.text
        emitted_change = true
        has_change = true
      elseif target == 'right' then
        emitted = context_text(line)
      end
    elseif line.kind == 'delete' then
      if in_range(line.lnum, range_start, range_finish) then
        emitted = line.text
        emitted_change = true
        has_change = true
      elseif target == 'left' then
        emitted = context_text(line)
      end
    end

    if emitted then
      patch_lines[#patch_lines + 1] = emitted
    end
    previous_emitted_change = emitted_change
  end

  if not has_change then
    return nil, 'visual selection does not include changed Gdiff lines'
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
---@param opts? { recount?: boolean }
---@return boolean, string?
local function checked_apply(repo_root, patch, operation, opts)
  opts = opts or {}
  local reverse = operation == 'unstage'
  local ok, output = git.apply_patch(repo_root, patch, {
    cached = true,
    reverse = reverse,
    check = true,
    recount = opts.recount,
  })
  if not ok then
    return false, format_git_output(output)
  end

  ok, output = git.apply_patch(repo_root, patch, {
    cached = true,
    reverse = reverse,
    recount = opts.recount,
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

---@param bufnr integer
---@param range_start integer
---@param range_finish integer
---@return diffs.GdiffHunk?, diffs.DiffSpec?, string?
local function range_action_context(bufnr, range_start, range_finish)
  if range_finish < range_start then
    range_start, range_finish = range_finish, range_start
  end

  local parsed = buffer_hunks(bufnr)
  local start_hunk = hunk_model.hunk_at_line(parsed, range_start)
  local finish_hunk = hunk_model.hunk_at_line(parsed, range_finish)
  if not start_hunk or not finish_hunk or start_hunk.index ~= finish_hunk.index then
    return nil, nil, 'visual selection must stay within one Gdiff hunk'
  end

  local spec = hunk_diff_spec(start_hunk)
  if not spec then
    return nil, nil, 'cannot resolve Gdiff hunk edge'
  end

  return start_hunk, spec, nil
end

---@param message string
---@param level integer
local function notify(message, level)
  vim.notify('[diffs]: ' .. message, level)
end

---@param bufnr integer
---@param hunk diffs.GdiffHunk
---@param operation "stage"|"unstage"
---@param opts? { patch?: string, recount?: boolean }
---@return boolean
local function mutate_hunk(bufnr, hunk, operation, opts)
  opts = opts or {}
  local repo_root = get_buf_var(bufnr, 'diffs_repo_root')
  if not repo_root then
    notify('cannot mutate Gdiff hunk without diffs_repo_root', vim.log.levels.ERROR)
    return false
  end

  local patch, patch_err = opts.patch, nil
  if not patch then
    patch, patch_err = M.patch_for_hunk(hunk)
  end
  if not patch then
    notify(patch_err or 'cannot build hunk patch', vim.log.levels.ERROR)
    return false
  end

  local ok, err = checked_apply(repo_root, patch, operation, { recount = opts.recount })
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

---@param bufnr integer
---@param range_start integer
---@param range_finish integer
---@return diffs.GdiffHunk?, diffs.DiffSpec?, string?
local function range_context_or_notify(bufnr, range_start, range_finish)
  local hunk, spec, err = range_action_context(bufnr, range_start, range_finish)
  if err then
    notify(err, vim.log.levels.WARN)
    return nil, nil, err
  end
  if not hunk or not spec then
    local fallback = 'cannot resolve Gdiff hunk edge'
    notify(fallback, vim.log.levels.WARN)
    return nil, nil, fallback
  end

  return hunk, spec, nil
end

---@param hunk diffs.GdiffHunk
---@param range_start integer
---@param range_finish integer
---@param target "left"|"right"
---@return string?
local function range_patch_or_notify(hunk, range_start, range_finish, target)
  local patch, patch_err = M.patch_for_range(hunk, range_start, range_finish, {
    target = target,
  })
  if not patch then
    notify(patch_err or 'cannot build hunk patch', vim.log.levels.WARN)
    return nil
  end

  return patch
end

---@param bufnr integer
---@param range_start integer
---@param range_finish integer
---@return boolean
function M.put_range(bufnr, range_start, range_finish)
  local hunk, spec = range_context_or_notify(bufnr, range_start, range_finish)
  if not hunk or not spec then
    return false
  end

  if is_index_to_worktree(spec) then
    local patch = range_patch_or_notify(hunk, range_start, range_finish, 'left')
    if not patch then
      return false
    end
    return mutate_hunk(bufnr, hunk, 'stage', {
      patch = patch,
      recount = true,
    })
  end

  if is_tree_to_index(spec) then
    notify('Gdiff hunk is already in the index', vim.log.levels.WARN)
    return false
  end

  notify('cannot put read-only Gdiff hunk', vim.log.levels.WARN)
  return false
end

---@param bufnr integer
---@param range_start integer
---@param range_finish integer
---@return boolean
function M.obtain_range(bufnr, range_start, range_finish)
  local hunk, spec = range_context_or_notify(bufnr, range_start, range_finish)
  if not hunk or not spec then
    return false
  end

  if is_tree_to_index(spec) then
    local patch = range_patch_or_notify(hunk, range_start, range_finish, 'right')
    if not patch then
      return false
    end
    return mutate_hunk(bufnr, hunk, 'unstage', {
      patch = patch,
      recount = true,
    })
  end

  if is_index_to_worktree(spec) then
    notify('restoring worktree hunks is not supported', vim.log.levels.WARN)
    return false
  end

  notify('cannot obtain read-only Gdiff hunk', vim.log.levels.WARN)
  return false
end

return M
