local M = {}

local diffspec = require('diffs.spec')

---@class diffs.DiffParseContext
---@field path string
---@field current? diffs.Endpoint

---@class diffs.DiffParseResult
---@field spec diffs.DiffSpec
---@field layout "unified"|"stacked"|"split"

local function normalize_rev(rev)
  if rev == '@' then
    return 'HEAD'
  end
  return rev
end

---@param args? string
---@return string[]
local function split_args(args)
  args = vim.trim(args or '')
  if args == '' then
    return {}
  end
  return vim.split(args, '%s+', { trimempty = true })
end

---@param endpoint diffs.Endpoint
---@return boolean
local function is_index(endpoint)
  return endpoint.kind == diffspec.endpoint_kind.index
end

---@param endpoint diffs.Endpoint
---@return boolean
local function is_worktree(endpoint)
  return endpoint.kind == diffspec.endpoint_kind.worktree
end

---@class diffs.DiffParsedObject
---@field left diffs.Endpoint
---@field path? string # explicit path; nil means the current file
---@field right_worktree? boolean # if set, the right endpoint is the worktree rather than `current`

--- Parse a single `:Diff` object into its left endpoint, optional explicit
--- path, and whether the right endpoint should be pinned to the worktree.
--- Recognizable Fugitive forms that are intentionally unsupported are rejected
--- with specific messages (see |diffs.nvim-diff-objects|).
---@param object string
---@return diffs.DiffParsedObject?, string?
local function parse_object(object)
  if object == '#' or object:match('^#%d+$') then
    return nil, 'alternate-buffer objects (#) are not supported'
  end
  if object:sub(1, 1) == '!' then
    return nil, 'owner-commit objects (!) are not supported'
  end
  if object == '<cfile>' then
    return nil, '<cfile> objects are not supported'
  end
  if object == '-' then
    return nil, 'the previous-object form (-) is not supported'
  end
  if object == '.' or object:sub(1, 2) == './' or object:sub(1, 3) == '../' then
    return nil, 'worktree-relative path objects (./) are not supported'
  end
  if object:find('..', 1, true) then
    return nil, 'range objects are not supported; use :Diff review for ranges'
  end
  if object:match('^:/') then
    return nil, 'commit-message search objects (:/) are not supported'
  end
  if object:match('^:%(') then
    return nil, 'pathspec-magic objects (:(...)) are not supported'
  end

  if object == ':' or object == ':%' or object == ':0:%' then
    return { left = diffspec.index() }, nil
  end

  local stage_digit, stage_rest = object:match('^:([0-3]):(.+)$')
  if stage_digit then
    local left
    if stage_digit == '0' then
      left = diffspec.index()
    elseif stage_digit == '1' then
      left = diffspec.stage(1)
    elseif stage_digit == '2' then
      left = diffspec.stage(2)
    else
      left = diffspec.stage(3)
    end
    return {
      left = left,
      path = stage_rest ~= '%' and stage_rest or nil,
      right_worktree = true,
    },
      nil
  end

  if object:match('^:[123]$') then
    return nil,
      'merge stage ' .. object .. ' needs a path; use ' .. object .. ':% for the current file'
  end

  if object:sub(1, 1) == ':' then
    local object_path = object:sub(2)
    if object_path == '%' then
      return { left = diffspec.index() }, nil
    end
    return { left = diffspec.index(), path = object_path, right_worktree = true }, nil
  end

  if object:match(':$') then
    return nil, 'tree objects (trailing :) are not supported'
  end

  -- Greedy: `a:b:c` splits at the last colon. Git revisions rarely contain
  -- colons, and an invalid revision surfaces later when its content is read.
  local rev, rev_path = object:match('^(.+):(.+)$')
  if rev then
    if rev_path == '%' then
      return { left = diffspec.tree(normalize_rev(rev)) }, nil
    end
    return {
      left = diffspec.tree(normalize_rev(rev)),
      path = rev_path,
      right_worktree = true,
    },
      nil
  end

  return { left = diffspec.tree(normalize_rev(object)) }, nil
end

---@param current diffs.Endpoint
---@param path string
---@return diffs.DiffSpec
local function default_spec(current, path)
  if is_worktree(current) then
    return diffspec.index_to_worktree(path)
  end
  if is_index(current) then
    return diffspec.head_to_index(path)
  end
  return diffspec.file(diffspec.worktree(), current, path)
end

---@param args? string
---@param context diffs.DiffParseContext
---@return diffs.DiffParseResult?, string?
function M.parse(args, context)
  if not context or type(context) ~= 'table' then
    error('diffs: diff parse context must be a table')
  end
  local path = context.path
  if type(path) ~= 'string' or path == '' then
    error('diffs: diff parse context path must be a non-empty string')
  end

  local current = context.current and diffspec.endpoint(context.current) or diffspec.worktree()
  local tokens = split_args(args)
  local layout = 'unified'
  local has_layout = false

  while tokens[1] and tokens[1]:match('^%+%+') do
    if tokens[1]:match('^%+%+layout=') then
      if has_layout then
        return nil, 'repeated ++layout option'
      end
      local value = tokens[1]:match('^%+%+layout=(.+)$')
      if value ~= 'unified' and value ~= 'stacked' and value ~= 'split' then
        return nil, 'unsupported layout ' .. tostring(value)
      end
      has_layout = true
      layout = value
      table.remove(tokens, 1)
    else
      return nil, 'unknown option ' .. tokens[1]
    end
  end

  if tokens[1] and tokens[1]:match('^%-%-') then
    return nil, 'unsupported option ' .. tokens[1]
  end

  if #tokens > 1 then
    return nil, 'expected at most one Fugitive object'
  end

  if #tokens == 0 then
    return {
      spec = default_spec(current, path),
      layout = layout,
    }, nil
  end

  local object, err = parse_object(tokens[1])
  if not object then
    return nil, err
  end

  local scope_path = object.path or path
  local right = object.right_worktree and diffspec.worktree() or current
  return {
    spec = diffspec.file(object.left, right, scope_path),
    layout = layout,
  }, nil
end

M._test = {
  normalize_rev = normalize_rev,
  split_args = split_args,
}

return M
