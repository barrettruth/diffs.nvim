local M = {}

M.endpoint_kind = {
  tree = 'tree',
  index = 'index',
  worktree = 'worktree',
  stage = 'stage',
}

M.scope_kind = {
  file = 'file',
}

local function require_table(value, name)
  if type(value) ~= 'table' then
    error('diffs: ' .. name .. ' must be a table')
  end
end

local function require_non_empty_string(value, name)
  if type(value) ~= 'string' or value == '' then
    error('diffs: ' .. name .. ' must be a non-empty string')
  end
end

---@class diffs.TreeEndpoint
---@field kind "tree"
---@field rev string

---@class diffs.IndexEndpoint
---@field kind "index"

---@class diffs.WorktreeEndpoint
---@field kind "worktree"

---@class diffs.StageEndpoint
---@field kind "stage"
---@field stage 1|2|3

---@alias diffs.Endpoint diffs.TreeEndpoint|diffs.IndexEndpoint|diffs.WorktreeEndpoint|diffs.StageEndpoint

---@class diffs.FileScope
---@field kind "file"
---@field path string

---@alias diffs.Scope diffs.FileScope

---@class diffs.DiffSpec
---@field left diffs.Endpoint
---@field right diffs.Endpoint
---@field scope diffs.Scope
---@field mode "unified"

---@param rev string
---@return diffs.TreeEndpoint
function M.tree(rev)
  require_non_empty_string(rev, 'tree endpoint rev')
  return { kind = M.endpoint_kind.tree, rev = rev }
end

M.revision = M.tree

---@return diffs.IndexEndpoint
function M.index()
  return { kind = M.endpoint_kind.index }
end

---@return diffs.WorktreeEndpoint
function M.worktree()
  return { kind = M.endpoint_kind.worktree }
end

---@param stage 1|2|3
---@return diffs.StageEndpoint
function M.stage(stage)
  if stage ~= 1 and stage ~= 2 and stage ~= 3 then
    error('diffs: stage endpoint must be 1, 2, or 3')
  end
  return { kind = M.endpoint_kind.stage, stage = stage }
end

---@param endpoint diffs.Endpoint
---@return diffs.Endpoint
function M.endpoint(endpoint)
  require_table(endpoint, 'endpoint')

  if endpoint.kind == M.endpoint_kind.tree then
    return M.tree(endpoint.rev)
  end

  if endpoint.kind == M.endpoint_kind.index then
    return M.index()
  end

  if endpoint.kind == M.endpoint_kind.worktree then
    return M.worktree()
  end

  if endpoint.kind == M.endpoint_kind.stage then
    return M.stage(endpoint.stage)
  end

  error('diffs: unsupported endpoint kind: ' .. tostring(endpoint.kind))
end

---@param path string
---@return diffs.FileScope
function M.file_scope(path)
  require_non_empty_string(path, 'file scope path')
  return { kind = M.scope_kind.file, path = path }
end

---@param scope diffs.Scope
---@return diffs.Scope
function M.scope(scope)
  require_table(scope, 'scope')

  if scope.kind == M.scope_kind.file then
    return M.file_scope(scope.path)
  end

  error('diffs: unsupported scope kind: ' .. tostring(scope.kind))
end

---@param opts diffs.DiffSpec
---@return diffs.DiffSpec
function M.new(opts)
  require_table(opts, 'diff spec')

  local mode = opts.mode or 'unified'
  if mode ~= 'unified' then
    error('diffs: diff spec mode must be "unified"')
  end

  return {
    left = M.endpoint(opts.left),
    right = M.endpoint(opts.right),
    scope = M.scope(opts.scope),
    mode = mode,
  }
end

---@param left diffs.Endpoint
---@param right diffs.Endpoint
---@param path string
---@return diffs.DiffSpec
function M.file(left, right, path)
  return M.new({
    left = left,
    right = right,
    scope = M.file_scope(path),
    mode = 'unified',
  })
end

---@param path string
---@return diffs.DiffSpec
function M.index_to_worktree(path)
  return M.file(M.index(), M.worktree(), path)
end

---@param path string
---@return diffs.DiffSpec
function M.head_to_index(path)
  return M.file(M.tree('HEAD'), M.index(), path)
end

---@param rev string
---@param path string
---@return diffs.DiffSpec
function M.rev_to_worktree(rev, path)
  return M.file(M.tree(rev), M.worktree(), path)
end

---@param left_rev string
---@param right_rev string
---@param path string
---@return diffs.DiffSpec
function M.rev_to_rev(left_rev, right_rev, path)
  return M.file(M.tree(left_rev), M.tree(right_rev), path)
end

---@param stage 1|2|3
---@param path string
---@return diffs.DiffSpec
function M.stage_to_worktree(stage, path)
  return M.file(M.stage(stage), M.worktree(), path)
end

---@param endpoint diffs.Endpoint
---@return string
function M.endpoint_label(endpoint)
  endpoint = M.endpoint(endpoint)

  if endpoint.kind == M.endpoint_kind.tree then
    return 'tree:' .. endpoint.rev
  end

  if endpoint.kind == M.endpoint_kind.stage then
    return 'stage:' .. endpoint.stage
  end

  return endpoint.kind
end

---@param scope diffs.Scope
---@return string
function M.scope_label(scope)
  scope = M.scope(scope)
  return scope.kind .. ':' .. scope.path
end

---@param diff_spec diffs.DiffSpec
---@return string
function M.label(diff_spec)
  diff_spec = M.new(diff_spec)
  return M.endpoint_label(diff_spec.left)
    .. ' -> '
    .. M.endpoint_label(diff_spec.right)
    .. ' '
    .. M.scope_label(diff_spec.scope)
end

---@param diff_spec diffs.DiffSpec
---@return "index"|"worktree"|nil
function M.mutation_target(diff_spec)
  diff_spec = M.new(diff_spec)

  -- Merge-stage comparisons are read-only: a stage blob cannot be staged or
  -- restored through hunk actions.
  if diff_spec.left.kind == M.endpoint_kind.stage then
    return nil
  end

  if diff_spec.right.kind == M.endpoint_kind.index then
    return M.endpoint_kind.index
  end

  if diff_spec.right.kind == M.endpoint_kind.worktree then
    return M.endpoint_kind.worktree
  end

  return nil
end

---@param diff_spec diffs.DiffSpec
---@return { can_put: boolean, can_obtain: boolean }
function M.patch_actions(diff_spec)
  diff_spec = M.new(diff_spec)

  return {
    can_put = diff_spec.left.kind == M.endpoint_kind.index
      and diff_spec.right.kind == M.endpoint_kind.worktree,
    can_obtain = diff_spec.left.kind == M.endpoint_kind.tree
      and diff_spec.right.kind == M.endpoint_kind.index,
  }
end

---@param diff_spec diffs.DiffSpec
---@return boolean
function M.is_index_target(diff_spec)
  return M.mutation_target(diff_spec) == M.endpoint_kind.index
end

---@param diff_spec diffs.DiffSpec
---@return boolean
function M.is_worktree_target(diff_spec)
  return M.mutation_target(diff_spec) == M.endpoint_kind.worktree
end

---@param diff_spec diffs.DiffSpec
---@return boolean
function M.is_read_only(diff_spec)
  return M.mutation_target(diff_spec) == nil
end

---@param diff_spec diffs.DiffSpec
---@return { read_only: boolean, target: "index"|"worktree"|nil }
function M.mutability(diff_spec)
  local target = M.mutation_target(diff_spec)
  return {
    read_only = target == nil,
    target = target,
  }
end

return M
