local M = {}

local diffspec = require('diffs.spec')
local hunk_model = require('diffs.hunks')

---@param bufnr integer
---@param name string
---@return any
function M.get_var(bufnr, name)
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  if ok then
    return value
  end
  return nil
end

---@param bufnr integer
---@return string?
function M.repo_root(bufnr)
  return M.get_var(bufnr, 'diffs_repo_root')
end

---@param bufnr integer
---@param repo_root string
function M.set_repo_root(bufnr, repo_root)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', repo_root)
end

---@param bufnr integer
---@param diff_spec diffs.DiffSpec
function M.set_spec(bufnr, diff_spec)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_spec', diffspec.new(diff_spec))
end

---@param bufnr integer
---@return diffs.DiffSpec?, string?
function M.spec(bufnr)
  local raw = M.get_var(bufnr, 'diffs_spec')
  if raw == nil then
    return nil, nil
  end

  local ok, parsed = pcall(diffspec.new, raw)
  if not ok then
    return nil, tostring(parsed)
  end

  return parsed, nil
end

---@param bufnr integer
---@return boolean, any
function M.raw_hunks(bufnr)
  return pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_hunks')
end

---@param bufnr integer
---@return diffs.GdiffHunk[]
function M.hunks(bufnr)
  local ok, parsed = M.raw_hunks(bufnr)
  if ok and type(parsed) == 'table' then
    return parsed
  end
  return {}
end

---@param bufnr integer
---@param hunks diffs.GdiffHunk[]
function M.set_hunks(bufnr, hunks)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_hunks', hunks)
end

---@param bufnr integer
---@param diff_lines string[]
---@param diff_spec diffs.DiffSpec
function M.set_hunks_from_lines(bufnr, diff_lines, diff_spec)
  M.set_hunks(bufnr, hunk_model.parse(diff_lines, diff_spec))
end

---@param bufnr integer
function M.clear_hunks(bufnr)
  pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_hunks')
end

---@class diffs.GeneratedBufferSource
---@field version integer
---@field kind "file"|"file_pair"|"section"|"review"|"unmerged"|"split_endpoint"
---@field repo_root string
---@field spec? diffs.DiffSpec
---@field edge? "staged"|"unstaged"
---@field path? string
---@field old_path? string
---@field section? "staged"|"unstaged"
---@field review? diffs.GreviewSpec
---@field working_path? string
---@field side? "left"|"right"
---@field filetype? string
---@field quickfix? boolean

---@param source table
---@return diffs.GeneratedBufferSource?
function M.normalize_source(source)
  if type(source) ~= 'table' then
    error('expected table')
  end
  if source.version ~= 1 then
    error('expected version 1')
  end
  if type(source.repo_root) ~= 'string' or source.repo_root == '' then
    error('expected repo_root')
  end

  if source.kind == 'file' then
    if source.spec == nil then
      error('expected file spec')
    end
    source.spec = diffspec.new(source.spec)
  elseif source.kind == 'split_endpoint' then
    if source.spec == nil then
      error('expected split endpoint spec')
    end
    source.spec = diffspec.new(source.spec)
    if source.side ~= 'left' and source.side ~= 'right' then
      error('expected split endpoint side')
    end
    if type(source.path) ~= 'string' or source.path == '' then
      error('expected split endpoint path')
    end
  elseif source.kind == 'file_pair' then
    if source.edge ~= 'staged' and source.edge ~= 'unstaged' then
      error('expected file_pair edge')
    end
    if type(source.path) ~= 'string' or source.path == '' then
      error('expected file_pair path')
    end
    if type(source.old_path) ~= 'string' or source.old_path == '' then
      error('expected file_pair old_path')
    end
  elseif source.kind == 'section' then
    if source.section ~= 'staged' and source.section ~= 'unstaged' then
      error('expected section')
    end
  elseif source.kind == 'review' then
    if type(source.review) ~= 'table' then
      error('expected review spec')
    end
  elseif source.kind == 'unmerged' then
    if type(source.path) ~= 'string' or source.path == '' then
      error('expected unmerged path')
    end
  else
    error('unknown source kind')
  end

  return source
end

---@param bufnr integer
---@return diffs.GeneratedBufferSource?, string?
function M.source(bufnr)
  local raw = M.get_var(bufnr, 'diffs_source')
  if raw == nil then
    return nil, nil
  end

  local ok, source = pcall(M.normalize_source, raw)
  if not ok then
    return nil, tostring(source)
  end

  return source, nil
end

---@param bufnr integer
---@param source diffs.GeneratedBufferSource|diffs.SplitEndpointSource
function M.set_source(bufnr, source)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_source', source)
end

---@param repo_root string
---@param diff_spec diffs.DiffSpec
---@return diffs.GeneratedBufferSource
function M.file_source(repo_root, diff_spec)
  return {
    version = 1,
    kind = 'file',
    repo_root = repo_root,
    spec = diff_spec,
  }
end

---@param repo_root string
---@param edge "staged"|"unstaged"
---@param path string
---@param old_path string
---@return diffs.GeneratedBufferSource
function M.file_pair_source(repo_root, edge, path, old_path)
  return {
    version = 1,
    kind = 'file_pair',
    repo_root = repo_root,
    edge = edge,
    path = path,
    old_path = old_path,
  }
end

---@param repo_root string
---@param section "staged"|"unstaged"
---@return diffs.GeneratedBufferSource
function M.section_source(repo_root, section)
  return {
    version = 1,
    kind = 'section',
    repo_root = repo_root,
    section = section,
  }
end

---@param repo_root string
---@param path string
---@param working_path string?
---@return diffs.GeneratedBufferSource
function M.unmerged_source(repo_root, path, working_path)
  return {
    version = 1,
    kind = 'unmerged',
    repo_root = repo_root,
    path = path,
    working_path = working_path,
  }
end

---@param repo_root string
---@param review diffs.GreviewSpec
---@return diffs.GeneratedBufferSource
function M.review_source(repo_root, review)
  return {
    version = 1,
    kind = 'review',
    repo_root = repo_root,
    review = review,
  }
end

---@param opts { repo_root: string, spec: diffs.DiffSpec, side: "left"|"right", path: string, filetype?: string, quickfix?: boolean }
---@return diffs.SplitEndpointSource
function M.split_endpoint_source(opts)
  return {
    version = 1,
    kind = 'split_endpoint',
    repo_root = opts.repo_root,
    spec = opts.spec,
    side = opts.side,
    path = opts.path,
    filetype = opts.filetype,
    quickfix = opts.quickfix,
  }
end

return M
