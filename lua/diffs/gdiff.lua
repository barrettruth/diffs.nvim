local M = {}

local diffspec = require('diffs.spec')

---@class diffs.GdiffParseContext
---@field path string
---@field current? diffs.Endpoint

---@class diffs.GdiffParseResult
---@field spec diffs.DiffSpec
---@field novertical boolean

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

---@param object string
---@return diffs.Endpoint?, string?
local function parse_object_endpoint(object)
  if object == ':' or object == ':%' or object == ':0:%' then
    return diffspec.index(), nil
  end

  local stage = object:match('^:(%d):%%$')
  if stage then
    return nil, 'unsupported index stage :' .. stage .. ':%'
  end

  local rev = object:match('^(.+):%%$')
  if rev then
    return diffspec.tree(normalize_rev(rev)), nil
  end

  if object:find(':', 1, true) then
    return nil, 'unsupported Fugitive object: ' .. object
  end

  return diffspec.tree(normalize_rev(object)), nil
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
---@param context diffs.GdiffParseContext
---@return diffs.GdiffParseResult?, string?
function M.parse(args, context)
  if not context or type(context) ~= 'table' then
    error('diffs: gdiff parse context must be a table')
  end
  local path = context.path
  if type(path) ~= 'string' or path == '' then
    error('diffs: gdiff parse context path must be a non-empty string')
  end

  local current = context.current and diffspec.endpoint(context.current) or diffspec.worktree()
  local tokens = split_args(args)
  local novertical = false

  while tokens[1] and tokens[1]:match('^%+%+') do
    if tokens[1] == '++novertical' then
      novertical = true
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
      novertical = novertical,
    }, nil
  end

  local endpoint, err = parse_object_endpoint(tokens[1])
  if not endpoint then
    return nil, err
  end

  return {
    spec = diffspec.file(endpoint, current, path),
    novertical = novertical,
  }, nil
end

M._test = {
  normalize_rev = normalize_rev,
  split_args = split_args,
}

return M
