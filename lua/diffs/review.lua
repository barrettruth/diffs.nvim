local M = {}

local git = require('diffs.git')
local log = require('diffs.log')

local dbg = log.dbg
local notify = log.notify

---@class diffs.GreviewSpec
---@field base? string
---@field target? string
---@field repo? string
---@field mode? string
---@field vertical? boolean

---@class diffs.NormalizedGreview
---@field base string
---@field target string?
---@field repo_root string
---@field mode string?
---@field vertical boolean
---@field display string
---@field exec_args string[]

---@class diffs.ReviewDeps
---@field create_generated_diff_buffer fun(opts: diffs.GeneratedDiffBufferOpts): integer
---@field show_generated_diff_buffer fun(bufnr: integer, vertical?: boolean)
---@field attach_generated_diff_buffer fun(bufnr: integer)
---@field replace_combined_diffs fun(lines: string[], repo_root: string): string[]

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

---@param repo? string
---@return string?
local function resolve_repo_root(repo)
  if repo and repo ~= '' then
    return git.get_repo_root(repo .. '/.')
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local repo_root = git.get_repo_root(filepath ~= '' and filepath or nil)
  if repo_root then
    return repo_root
  end

  local cwd = vim.fn.getcwd()
  return git.get_repo_root(cwd .. '/.')
end

---@param repo_root string
---@return string?
local function default_branch(repo_root)
  local ref =
    vim.fn.systemlist({ 'git', '-C', repo_root, 'symbolic-ref', 'refs/remotes/origin/HEAD' })
  if vim.v.shell_error ~= 0 or not ref[1] or ref[1] == '' then
    return nil
  end
  return ref[1]:gsub('^refs/remotes/', '')
end

---@param repo_root string
---@param args string[]
---@return boolean
local function git_exits_zero(repo_root, args)
  local cmd = { 'git', '-C', repo_root }
  vim.list_extend(cmd, args)
  vim.fn.systemlist(cmd)
  return vim.v.shell_error == 0
end

---@param repo_root string
---@param ref string
---@return boolean
local function ref_exists(repo_root, ref)
  return git_exits_zero(repo_root, { 'rev-parse', '--verify', '--quiet', ref .. '^{commit}' })
end

---@param repo_root string
---@param base string
---@param target string
---@return boolean
local function merge_base_exists(repo_root, base, target)
  return git_exits_zero(repo_root, { 'merge-base', base, target })
end

---@param repo_root string
---@param base string
---@param target string?
---@param mode string?
---@param display string
---@return string?
local function validate_refs(repo_root, base, target, mode, display)
  if not ref_exists(repo_root, base) then
    return ('Greview base ref not found: %s (spec: %s)'):format(base, display)
  end

  if target and not ref_exists(repo_root, target) then
    return ('Greview target ref not found: %s (spec: %s)'):format(target, display)
  end

  if target and mode == 'merge-base' and not merge_base_exists(repo_root, base, target) then
    return 'Greview merge base not found for spec: ' .. display
  end

  return nil
end

---@param arg? string
---@return diffs.GreviewSpec?, string?
function M.parse_arg(arg)
  if not arg or arg == '' then
    return {}, nil
  end

  local base, target = arg:match('^(.-)%.%.%.(.+)$')
  if base then
    if base == '' or target == '' then
      return nil, 'invalid review spec'
    end
    return { base = base, target = target, mode = 'merge-base' }, nil
  end

  base, target = arg:match('^(.-)%.%.(.+)$')
  if base then
    if base == '' or target == '' then
      return nil, 'invalid review spec'
    end
    return { base = base, target = target, mode = 'direct' }, nil
  end

  return { base = arg }, nil
end

---@param spec? diffs.GreviewSpec
---@param repo_root_override? string
---@return diffs.NormalizedGreview?, string?
function M.normalize(spec, repo_root_override)
  spec = spec or {}
  if type(spec) ~= 'table' then
    error('diffs: greview() expects a table spec')
  end
  if spec.base ~= nil and type(spec.base) ~= 'string' then
    error('diffs: greview.base must be a string')
  end
  if spec.target ~= nil and type(spec.target) ~= 'string' then
    error('diffs: greview.target must be a string')
  end
  if spec.repo ~= nil and type(spec.repo) ~= 'string' then
    error('diffs: greview.repo must be a string')
  end
  if spec.mode ~= nil and type(spec.mode) ~= 'string' then
    error('diffs: greview.mode must be a string')
  end
  if spec.vertical ~= nil and type(spec.vertical) ~= 'boolean' then
    error('diffs: greview.vertical must be a boolean')
  end

  local repo_root = repo_root_override or resolve_repo_root(spec.repo)
  if not repo_root then
    return nil, 'not in a git repository'
  end

  local base = spec.base
  if not base or base == '' then
    base = default_branch(repo_root)
    if not base then
      return nil, 'cannot detect default branch (try: git remote set-head origin -a)'
    end
  end

  local target = spec.target
  if target == '' then
    error('diffs: greview.target must be a non-empty string')
  end

  local mode = spec.mode
  if target then
    if mode == nil then
      mode = 'merge-base'
    elseif mode ~= 'merge-base' and mode ~= 'direct' then
      error('diffs: greview.mode must be "merge-base" or "direct"')
    end
  elseif mode ~= nil then
    error('diffs: greview.mode requires greview.target')
  end

  local display = base
  local exec_args = { base }
  if target then
    if mode == 'merge-base' then
      display = base .. '...' .. target
      exec_args = { '--merge-base', base, target }
    else
      display = base .. '..' .. target
      exec_args = { base, target }
    end
  end

  local ref_err = validate_refs(repo_root, base, target, mode, display)
  if ref_err then
    return nil, ref_err
  end

  return {
    base = base,
    target = target,
    repo_root = repo_root,
    mode = mode,
    vertical = spec.vertical or false,
    display = display,
    exec_args = exec_args,
  },
    nil
end

---@param review diffs.NormalizedGreview
---@return string[]
function M.build_cmd(review)
  local cmd = { 'git', '-C', review.repo_root, 'diff', '--no-ext-diff', '--no-color' }
  vim.list_extend(cmd, review.exec_args)
  return cmd
end

---@param review diffs.NormalizedGreview
---@return string
function M.buffer_name(review)
  return 'diffs://review:' .. review.display
end

---@param repo_root? string
---@return string[]
local function list_refs(repo_root)
  local cmd = { 'git' }
  if repo_root then
    table.insert(cmd, '-C')
    table.insert(cmd, repo_root)
  end
  vim.list_extend(cmd, {
    'for-each-ref',
    '--format=%(refname:short)',
    'refs/heads/',
    'refs/remotes/',
    'refs/tags/',
  })
  local refs = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return refs
end

---@param arglead string
---@return string[]
function M.complete(arglead)
  local refs = list_refs(resolve_repo_root(nil))
  if arglead == '' then
    return refs
  end

  local base, tail = arglead:match('^(.-)%.%.%.(.*)$')
  if base then
    if base == '' then
      return {}
    end
    local matches = {}
    for _, ref in ipairs(refs) do
      if ref:find(tail, 1, true) == 1 then
        table.insert(matches, base .. '...' .. ref)
      end
    end
    return matches
  end

  base, tail = arglead:match('^(.-)%.%.(.*)$')
  if base then
    if base == '' then
      return {}
    end
    local matches = {}
    for _, ref in ipairs(refs) do
      if ref:find(tail, 1, true) == 1 then
        table.insert(matches, base .. '..' .. ref)
      end
    end
    return matches
  end

  local matches = {}
  for _, ref in ipairs(refs) do
    if ref:find(arglead, 1, true) == 1 then
      table.insert(matches, ref)
    end
  end
  return matches
end

---@param review diffs.NormalizedGreview
---@param deps diffs.ReviewDeps
---@return string[]?, string?
function M.run(review, deps)
  local result = vim.fn.systemlist(M.build_cmd(review))
  if vim.v.shell_error ~= 0 then
    return nil, 'git diff failed for Greview spec: ' .. review.display
  end
  return deps.replace_combined_diffs(result, review.repo_root), nil
end

-- selene: allow(global_usage)
function _G._diffs_qftf(info)
  local items = info.quickfix == 1 and vim.fn.getqflist({ id = info.id, items = 0 }).items
    or vim.fn.getloclist(0, { id = info.id, items = 0 }).items
  local max_lnum = 0
  for i = info.start_idx, info.end_idx do
    local e = items[i]
    if e.lnum > 0 then
      max_lnum = math.max(max_lnum, #tostring(e.lnum))
    end
  end
  local lnum_fmt = '%' .. math.max(max_lnum, 1) .. 'd'
  local lines = {}
  for i = info.start_idx, info.end_idx do
    local e = items[i]
    local text = e.text or ''
    if max_lnum > 0 and e.lnum > 0 then
      table.insert(lines, ('%s  %s'):format(lnum_fmt:format(e.lnum), text))
    else
      table.insert(lines, text)
    end
  end
  return lines
end

---@param diff_buf integer
---@param result string[]
---@return table[], table[]
function M.list_items(diff_buf, result)
  local qf_items = {}
  local loc_items = {}
  local current_file = nil
  local file_adds, file_dels = {}, {}
  local file_hunk_count = {}

  for i, line in ipairs(result) do
    local file = line:match('^diff %-%-git a/.+ b/(.+)$')
    if file then
      current_file = file
      file_adds[file] = 0
      file_dels[file] = 0
      file_hunk_count[file] = 0
      table.insert(qf_items, {
        bufnr = diff_buf,
        lnum = i,
        text = file,
      })
    elseif current_file and line:match('^@@') then
      file_hunk_count[current_file] = file_hunk_count[current_file] + 1
      table.insert(loc_items, {
        bufnr = diff_buf,
        lnum = i,
        text = current_file,
        _hunk = file_hunk_count[current_file],
        _header = line:match('^(@@.-@@)') or '',
      })
    elseif current_file then
      local ch = line:sub(1, 1)
      if ch == '+' and not line:match('^%+%+%+') then
        file_adds[current_file] = file_adds[current_file] + 1
      elseif ch == '-' and not line:match('^%-%-%-') then
        file_dels[current_file] = file_dels[current_file] + 1
      end
    end
  end

  local max_fname = 0
  local max_add, max_del = 0, 0
  for _, item in ipairs(qf_items) do
    max_fname = math.max(max_fname, #item.text)
    local a = file_adds[item.text] or 0
    local d = file_dels[item.text] or 0
    if a > 0 then
      max_add = math.max(max_add, #tostring(a) + 1)
    end
    if d > 0 then
      max_del = math.max(max_del, #tostring(d) + 1)
    end
  end

  for _, item in ipairs(qf_items) do
    local file = item.text
    local a = file_adds[file] or 0
    local d = file_dels[file] or 0
    local padded = file .. string.rep(' ', max_fname - #file)
    local parts = { padded }
    if max_add > 0 then
      parts[#parts + 1] = a > 0 and string.format('%' .. max_add .. 's', '+' .. a)
        or string.rep(' ', max_add)
    end
    if max_del > 0 then
      parts[#parts + 1] = d > 0 and string.format('%' .. max_del .. 's', '-' .. d)
        or string.rep(' ', max_del)
    end
    item.text = table.concat(parts, '  '):gsub('%s+$', '')
  end

  local max_loc_fname = 0
  for _, item in ipairs(loc_items) do
    max_loc_fname = math.max(max_loc_fname, #item.text)
  end
  for _, item in ipairs(loc_items) do
    item.text = item.text
      .. string.rep(' ', max_loc_fname - #item.text)
      .. '  (hunk '
      .. item._hunk
      .. ') '
      .. item._header
    item._hunk = nil
    item._header = nil
  end

  return qf_items, loc_items
end

---@param spec? diffs.GreviewSpec
---@param deps diffs.ReviewDeps
---@return integer?
function M.greview(spec, deps)
  local review, err = M.normalize(spec)
  if not review then
    notify(err, vim.log.levels.ERROR)
    return nil
  end

  local target_name = M.buffer_name(review)
  local existing_buf = vim.fn.bufnr(target_name)
  if existing_buf ~= -1 then
    pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
  end

  local result, diff_err = M.run(review, deps)
  if not result then
    notify(diff_err, vim.log.levels.ERROR)
    return nil
  end
  if #result == 0 then
    notify('no diff against ' .. review.display, vim.log.levels.INFO)
    return nil
  end

  local diff_buf = deps.create_generated_diff_buffer({
    name = target_name,
    lines = result,
    repo_root = review.repo_root,
    source = {
      version = 1,
      kind = 'review',
      repo_root = review.repo_root,
      review = {
        base = review.base,
        target = review.target,
        mode = review.mode,
      },
    },
    vars = {
      diffs_review_base = review.base,
      diffs_review_target = review.target,
      diffs_review_mode = review.mode,
    },
  })

  local qf_items, loc_items = M.list_items(diff_buf, result)
  vim.fn.setqflist({}, ' ', {
    title = 'review: ' .. review.display,
    items = qf_items,
    quickfixtextfunc = 'v:lua._diffs_qftf',
  })

  deps.show_generated_diff_buffer(diff_buf, review.vertical)

  vim.fn.setloclist(0, {}, ' ', {
    title = 'review hunks: ' .. review.display,
    items = loc_items,
    quickfixtextfunc = 'v:lua._diffs_qftf',
  })

  deps.attach_generated_diff_buffer(diff_buf)
  dbg('opened review buffer %d (%s)', diff_buf, review.display)

  return diff_buf
end

---@param buf integer
---@param lnum integer
---@return string?
function M.file_at_line(buf, lnum)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
  for i = #lines, 1, -1 do
    local file = lines[i]:match('^diff %-%-git a/.+ b/(.+)$')
    if file then
      return file
    end
  end
  return nil
end

---@param review_spec diffs.GreviewSpec?
---@param repo_root string
---@param deps diffs.ReviewDeps
---@return string[]?, string?
local function reload_spec(review_spec, repo_root, deps)
  local normalized, normalize_err = M.normalize(review_spec, repo_root)
  if not normalized then
    return nil, normalize_err
  end

  return M.run(normalized, deps)
end

---@param source diffs.GeneratedBufferSource
---@param deps diffs.ReviewDeps
---@return string[]?, string?
function M.reload_source(source, deps)
  return reload_spec(source.review, source.repo_root, deps)
end

---@param bufnr integer
---@param repo_root string
---@param path string
---@param deps diffs.ReviewDeps
---@return string[]?, string?
function M.reload(bufnr, repo_root, path, deps)
  local stored_base = get_buf_var(bufnr, 'diffs_review_base')
  local stored_target = get_buf_var(bufnr, 'diffs_review_target')
  local stored_mode = get_buf_var(bufnr, 'diffs_review_mode')

  local review_spec
  if stored_base then
    review_spec = {
      base = stored_base,
      target = stored_target,
      mode = stored_mode,
    }
  else
    local parse_err
    review_spec, parse_err = M.parse_arg(path)
    if not review_spec then
      return nil, parse_err
    end
  end

  return reload_spec(review_spec, repo_root, deps)
end

return M
