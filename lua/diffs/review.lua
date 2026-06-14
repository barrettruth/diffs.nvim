local M = {}

local diffopt = require('diffs.diffopt')
local diffspec = require('diffs.spec')
local generated = require('diffs.generated')
local git = require('diffs.git')
local lists = require('diffs.lists')
local log = require('diffs.log')
local render = require('diffs.render')

local dbg = log.dbg
local notify = log.notify

---@class diffs.ReviewSpec
---@field base? string
---@field target? string
---@field repo? string
---@field mode? string
---@field vertical? boolean

---@class diffs.ReviewCommandParseResult
---@field spec diffs.ReviewSpec
---@field layout "unified"|"stacked"|"split"

---@class diffs.NormalizedReview
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
---@field rail_style? diffs.RailStyle

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

---@param args? string
---@return string[]
local function split_args(args)
  args = vim.trim(args or '')
  if args == '' then
    return {}
  end
  return vim.split(args, '%s+', { trimempty = true })
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
---@param target string
---@return string?, string?
local function merge_base(repo_root, base, target)
  local result = vim.fn.systemlist({ 'git', '-C', repo_root, 'merge-base', base, target })
  if vim.v.shell_error ~= 0 or not result[1] or result[1] == '' then
    return nil, 'review merge base not found for spec: ' .. base .. '...' .. target
  end
  return result[1], nil
end

---@param repo_root string
---@param base string
---@param target string?
---@param mode string?
---@param display string
---@return string?
local function validate_refs(repo_root, base, target, mode, display)
  if not ref_exists(repo_root, base) then
    return ('review base ref not found: %s (spec: %s)'):format(base, display)
  end

  if target and not ref_exists(repo_root, target) then
    return ('review target ref not found: %s (spec: %s)'):format(target, display)
  end

  if target and mode == 'merge-base' and not merge_base_exists(repo_root, base, target) then
    return 'review merge base not found for spec: ' .. display
  end

  return nil
end

---@param arg? string
---@return diffs.ReviewSpec?, string?
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

---@param args? string
---@return diffs.ReviewCommandParseResult?, string?
function M.parse_command_args(args)
  local tokens = split_args(args)
  local layout = 'unified'
  local has_layout = false

  while tokens[1] and tokens[1]:match('^%+%+layout=') do
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
  end

  if #tokens > 1 then
    return nil, 'expected at most one review spec'
  end

  local spec, err = M.parse_arg(tokens[1])
  if not spec then
    return nil, err
  end

  return {
    spec = spec,
    layout = layout,
  }, nil
end

---@param spec? diffs.ReviewSpec
---@param repo_root_override? string
---@return diffs.NormalizedReview?, string?
function M.normalize(spec, repo_root_override)
  spec = spec or {}
  if type(spec) ~= 'table' then
    error('diffs: review() expects a table spec')
  end
  if spec.base ~= nil and type(spec.base) ~= 'string' then
    error('diffs: review.base must be a string')
  end
  if spec.target ~= nil and type(spec.target) ~= 'string' then
    error('diffs: review.target must be a string')
  end
  if spec.repo ~= nil and type(spec.repo) ~= 'string' then
    error('diffs: review.repo must be a string')
  end
  if spec.mode ~= nil and type(spec.mode) ~= 'string' then
    error('diffs: review.mode must be a string')
  end
  if spec.vertical ~= nil and type(spec.vertical) ~= 'boolean' then
    error('diffs: review.vertical must be a boolean')
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
    error('diffs: review.target must be a non-empty string')
  end

  local mode = spec.mode
  if target then
    if mode == nil then
      mode = 'merge-base'
    elseif mode ~= 'merge-base' and mode ~= 'direct' then
      error('diffs: review.mode must be "merge-base" or "direct"')
    end
  elseif mode ~= nil then
    error('diffs: review.mode requires review.target')
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

---@param review diffs.NormalizedReview
---@return string[]
function M.build_cmd(review)
  local cmd = {
    'git',
    '-C',
    review.repo_root,
    'diff',
    '--no-ext-diff',
    '--no-color',
    '--src-prefix=a/',
    '--dst-prefix=b/',
  }
  vim.list_extend(cmd, diffopt.git_flags())
  vim.list_extend(cmd, review.exec_args)
  return cmd
end

---@param repo_root string
---@param args string[]
---@return string[]?, string?
local function git_lines(repo_root, args)
  local cmd = { 'git', '-C', repo_root }
  vim.list_extend(cmd, args)
  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(result or {}, '\n')
  end
  return result, nil
end

---@param line string
---@return string?
local function diff_line_file(line)
  local old_path, new_path = line:match('^diff %-%-git a/(.-) b/(.+)$')
  return new_path or old_path
end

---@param diff_lines string[]
---@return table<string, boolean>
local function combined_diff_files(diff_lines)
  local files = {}
  for _, line in ipairs(diff_lines) do
    local file = line:match('^diff %-%-cc (.+)$') or line:match('^diff %-%-combined (.+)$')
    if file then
      files[file] = true
    end
  end
  return files
end

---@param diff_lines string[]
---@return table[]
local function file_records(diff_lines)
  local records = {}
  local current = nil
  for lnum, line in ipairs(diff_lines) do
    local file = diff_line_file(line)
    if file then
      if current then
        current.finish = lnum - 1
      end
      current = {
        file = file,
        start = lnum,
        finish = #diff_lines,
      }
      records[#records + 1] = current
    end
  end
  return records
end

---@param path string
---@return diffs.DiffSpec
local function unmerged_stage_spec(path)
  return diffspec.rev_to_rev(':2', ':3', path)
end

---@param diff_lines string[]
---@param spec_for_file fun(file: string): diffs.DiffSpec
---@return table<string, diffs.DiffSpec>
local function section_specs(diff_lines, spec_for_file)
  local specs = {}
  for _, record in ipairs(file_records(diff_lines)) do
    specs[record.file] = spec_for_file(record.file)
  end
  return specs
end

---@param review diffs.NormalizedReview
---@param base_rev string
---@return string[]?, string?
local function branch_lines(review, base_rev)
  local args = { 'diff', '--no-ext-diff', '--no-color', '--src-prefix=a/', '--dst-prefix=b/' }
  vim.list_extend(args, diffopt.git_flags())
  args[#args + 1] = base_rev
  args[#args + 1] = 'HEAD'
  return git_lines(review.repo_root, args)
end

---@param review diffs.NormalizedReview
---@param cached boolean
---@return string[]?, string?
local function worktree_edge_lines(review, cached)
  local args = { 'diff', '--no-ext-diff', '--no-color', '--src-prefix=a/', '--dst-prefix=b/' }
  vim.list_extend(args, diffopt.git_flags())
  if cached then
    args[#args + 1] = '--cached'
  end
  return git_lines(review.repo_root, args)
end

---@param review diffs.NormalizedReview
---@return string[]?, string?
local function untracked_paths(review)
  local paths = vim.fn.systemlist({
    'git',
    '-C',
    review.repo_root,
    'ls-files',
    '--others',
    '--exclude-standard',
  })
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(paths or {}, '\n')
  end

  table.sort(paths)
  return paths, nil
end

---@param repo_root string
---@param path string
---@return boolean
local function is_untracked_binary(repo_root, path)
  local result = vim.fn.systemlist({
    'git',
    '-C',
    repo_root,
    'diff',
    '--no-ext-diff',
    '--no-color',
    '--no-index',
    '--numstat',
    '--',
    '/dev/null',
    path,
  })
  if vim.v.shell_error ~= 0 and vim.v.shell_error ~= 1 then
    return false
  end

  for _, line in ipairs(result or {}) do
    if line:match('^%-%s+%-%s+') then
      return true
    end
  end
  return false
end

---@param lines string[]
---@param section table
---@param specs table<string, diffs.DiffSpec>
---@param state table
local function append_section(lines, section, specs, state)
  local records = file_records(section.lines)
  if #records == 0 then
    return
  end

  local header_lnum = #lines + 1
  lines[#lines + 1] = ('# %s: %s'):format(section.label, section.description)
  local section_start = header_lnum
  for _, line in ipairs(section.lines) do
    lines[#lines + 1] = line
  end

  local section_info = {
    id = section.id,
    label = section.label,
    start = section_start,
    finish = #lines,
  }
  state.sections[#state.sections + 1] = section_info

  for _, record in ipairs(records) do
    local key = section.id .. ':' .. record.file
    state.records[#state.records + 1] = {
      key = key,
      file = record.file,
      section = section.id,
      section_label = section.label,
      diff_spec = specs[record.file],
      start = section_start + record.start,
      finish = section_start + record.finish,
    }
  end
end

---@param records table[]
---@param lnum integer
---@param file string
---@return table?
local function record_for_line(records, lnum, file)
  for _, record in ipairs(records or {}) do
    if record.file == file and lnum >= record.start and lnum <= record.finish then
      return record
    end
  end
  return nil
end

---@param records table[]
---@return fun(lnum: integer, file: string): table?
local function metadata_for_records(records)
  return function(lnum, file)
    return record_for_line(records, lnum, file)
  end
end

---@param review diffs.NormalizedReview
---@param deps diffs.ReviewDeps
---@return string[]?, string?, table?
local function run_current_state(review, deps)
  local base_rev, merge_err = merge_base(review.repo_root, review.base, 'HEAD')
  if not base_rev then
    return nil, merge_err, nil
  end

  local lines = {}
  local state = {
    records = {},
    sections = {},
  }

  local branch, branch_err = branch_lines(review, base_rev)
  if not branch then
    return nil, branch_err ~= '' and branch_err or 'git diff failed for review Branch section', nil
  end
  local branch_rendered = deps.replace_combined_diffs(branch, review.repo_root)
  local branch_specs = section_specs(branch_rendered, function(file)
    return diffspec.rev_to_rev(base_rev, 'HEAD', file)
  end)
  append_section(lines, {
    id = 'branch',
    label = 'Branch',
    description = review.base .. '...' .. 'HEAD',
    lines = branch_rendered,
  }, branch_specs, state)

  local staged, staged_err = worktree_edge_lines(review, true)
  if not staged then
    return nil, staged_err ~= '' and staged_err or 'git diff failed for review Staged section', nil
  end
  local staged_rendered = deps.replace_combined_diffs(staged, review.repo_root)
  local staged_unmerged = combined_diff_files(staged)
  local staged_specs = section_specs(staged_rendered, function(file)
    return staged_unmerged[file] and unmerged_stage_spec(file) or diffspec.head_to_index(file)
  end)
  append_section(lines, {
    id = 'staged',
    label = 'Staged',
    description = 'HEAD -> index',
    lines = staged_rendered,
  }, staged_specs, state)

  local unstaged, unstaged_err = worktree_edge_lines(review, false)
  if not unstaged then
    return nil,
      unstaged_err ~= '' and unstaged_err or 'git diff failed for review Unstaged section',
      nil
  end
  local unstaged_rendered = deps.replace_combined_diffs(unstaged, review.repo_root)
  local unstaged_unmerged = combined_diff_files(unstaged)
  local unstaged_specs = section_specs(unstaged_rendered, function(file)
    return unstaged_unmerged[file] and unmerged_stage_spec(file) or diffspec.index_to_worktree(file)
  end)
  append_section(lines, {
    id = 'unstaged',
    label = 'Unstaged',
    description = 'index -> worktree',
    lines = unstaged_rendered,
  }, unstaged_specs, state)

  local untracked, untracked_err = untracked_paths(review)
  if not untracked then
    return nil,
      untracked_err ~= '' and untracked_err or 'git ls-files failed for review Untracked section',
      nil
  end
  local untracked_lines = {}
  local untracked_specs = {}
  for _, path in ipairs(untracked) do
    if is_untracked_binary(review.repo_root, path) then
      dbg('skipping binary untracked %s', path)
    else
      local spec = diffspec.index_to_worktree(path)
      local rendered, render_err = render.file(spec, review.repo_root)
      if rendered then
        for _, line in ipairs(rendered) do
          untracked_lines[#untracked_lines + 1] = line
        end
        untracked_specs[path] = spec
      elseif render_err then
        dbg('skipping untracked %s: %s', path, render_err)
      end
    end
  end
  append_section(lines, {
    id = 'untracked',
    label = 'Untracked',
    description = 'empty -> worktree',
    lines = untracked_lines,
  }, untracked_specs, state)

  return lines,
    nil,
    {
      metadata_for_line = metadata_for_records(state.records),
      sections = state.sections,
      store_hunks = true,
    }
end

---@param review_spec diffs.ReviewSpec?
---@param repo_root string
---@param path string
---@param selection? diffs.GeneratedFileSelection
---@return diffs.DiffSpec?, diffs.NormalizedReview?, string?
function M.diff_spec_for_file(review_spec, repo_root, path, selection)
  if type(path) ~= 'string' or path == '' then
    return nil, nil, 'missing review file path'
  end

  local normalized, normalize_err = M.normalize(review_spec, repo_root)
  if not normalized then
    return nil, nil, normalize_err
  end

  if selection and selection.diff_spec then
    return diffspec.new(selection.diff_spec), normalized, nil
  end

  if not normalized.target then
    return diffspec.rev_to_worktree(normalized.base, path), normalized, nil
  end

  if normalized.mode == 'merge-base' then
    local base_rev, merge_err = merge_base(normalized.repo_root, normalized.base, normalized.target)
    if not base_rev then
      return nil, normalized, merge_err
    end
    return diffspec.rev_to_rev(base_rev, normalized.target, path), normalized, nil
  end

  return diffspec.rev_to_rev(normalized.base, normalized.target, path), normalized, nil
end

---@param review diffs.NormalizedReview
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

---@param review diffs.NormalizedReview
---@param deps diffs.ReviewDeps
---@return string[]?, string?
function M.run(review, deps)
  local result = vim.fn.systemlist(M.build_cmd(review))
  if vim.v.shell_error ~= 0 then
    return nil, 'git diff failed for review spec: ' .. review.display
  end
  return deps.replace_combined_diffs(result, review.repo_root), nil
end

---@param review diffs.NormalizedReview
---@param deps diffs.ReviewDeps
---@return string[]?, string?, table?
function M.render(review, deps)
  if not review.target then
    return run_current_state(review, deps)
  end

  local result, err = M.run(review, deps)
  return result, err, nil
end

---@param spec? diffs.ReviewSpec
---@param deps diffs.ReviewDeps
---@return integer?
function M.open(spec, deps)
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

  local result, diff_err, list_opts = M.render(review, deps)
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
    source = generated.review_source(review.repo_root, {
      base = review.base,
      target = review.target,
      mode = review.mode,
    }),
    rail_style = deps.rail_style,
    vars = {
      diffs_review_base = review.base,
      diffs_review_target = review.target,
      diffs_review_mode = review.mode,
    },
  })

  deps.show_generated_diff_buffer(diff_buf, review.vertical)
  lists.set_for_unified_buffer(diff_buf, result, {
    title = 'review: ' .. review.display,
    loclist_title = 'review hunks: ' .. review.display,
    metadata_for_line = list_opts and list_opts.metadata_for_line,
    sections = list_opts and list_opts.sections,
    store_hunks = list_opts and list_opts.store_hunks,
    quickfix = true,
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

---@param review_spec diffs.ReviewSpec?
---@param repo_root string
---@param deps diffs.ReviewDeps
---@return string[]?, string?, table?
local function reload_spec(review_spec, repo_root, deps)
  local normalized, normalize_err = M.normalize(review_spec, repo_root)
  if not normalized then
    return nil, normalize_err, nil
  end

  return M.render(normalized, deps)
end

---@param source diffs.GeneratedBufferSource
---@param deps diffs.ReviewDeps
---@return string[]?, string?, table?
function M.reload_source(source, deps)
  return reload_spec(source.review, source.repo_root, deps)
end

---@param bufnr integer
---@param repo_root string
---@param path string
---@param deps diffs.ReviewDeps
---@return string[]?, string?, table?
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
