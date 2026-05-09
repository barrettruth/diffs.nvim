local M = {}

local diffspec = require('diffs.spec')
local gdiff_parser = require('diffs.gdiff')
local git = require('diffs.git')
local hunk_model = require('diffs.hunks')
local dbg = require('diffs.log').dbg
local render = require('diffs.render')
local runtime = require('diffs.runtime')

---@type table<integer, table<string, function>>
local hunk_keymaps = {}
---@type table<integer, integer>
local hunk_keymap_autocmds = {}

---@param bufnr integer
---@param lhs string
---@return table?
local function get_buffer_keymap(bufnr, lhs)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
    if keymap.lhs == lhs then
      return keymap
    end
  end
  return nil
end

---@param bufnr integer
local function clear_hunk_keymaps(bufnr)
  local registered = hunk_keymaps[bufnr]
  if not registered then
    return
  end
  for lhs, callback in pairs(registered) do
    local current = get_buffer_keymap(bufnr, lhs)
    if current and current.callback == callback then
      pcall(vim.keymap.del, 'n', lhs, { buffer = bufnr })
    end
  end
  hunk_keymaps[bufnr] = nil
end

---@param bufnr integer
local function ensure_hunk_keymap_cleanup(bufnr)
  if hunk_keymap_autocmds[bufnr] then
    return
  end

  hunk_keymap_autocmds[bufnr] = vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      hunk_keymaps[bufnr] = nil
      hunk_keymap_autocmds[bufnr] = nil
    end,
  })
end

---@param bufnr integer
---@param lhs string
---@param callback function
---@param desc string
local function set_hunk_keymap(bufnr, lhs, callback, desc)
  if get_buffer_keymap(bufnr, lhs) then
    return
  end

  vim.keymap.set('n', lhs, callback, { buffer = bufnr, desc = desc })
  hunk_keymaps[bufnr] = hunk_keymaps[bufnr] or {}
  hunk_keymaps[bufnr][lhs] = callback
end

---@return integer?
function M.find_diffs_window()
  local tabpage = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match('^diffs://') then
        return win
      end
    end
  end
  return nil
end

---@param bufnr integer
function M.setup_diff_buf(bufnr)
  vim.diagnostic.enable(false, { bufnr = bufnr })
  if not get_buffer_keymap(bufnr, 'q') then
    vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = bufnr })
  end
  local has_hunks = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_hunks')
  if not has_hunks then
    clear_hunk_keymaps(bufnr)
    return
  end

  set_hunk_keymap(bufnr, ']c', function()
    hunk_model.goto_next(bufnr)
  end, 'Next diff hunk')
  set_hunk_keymap(bufnr, '[c', function()
    hunk_model.goto_prev(bufnr)
  end, 'Previous diff hunk')
  set_hunk_keymap(bufnr, '<CR>', function()
    hunk_model.open_source(bufnr)
  end, 'Open source file')
  set_hunk_keymap(bufnr, 'o', function()
    hunk_model.open_source(bufnr)
  end, 'Open source file')

  ensure_hunk_keymap_cleanup(bufnr)
end

---@param diff_lines string[]
---@param hunk_position { hunk_header: string, offset: integer }
---@return integer?
function M.find_hunk_line(diff_lines, hunk_position)
  for i, line in ipairs(diff_lines) do
    if line == hunk_position.hunk_header then
      return i + hunk_position.offset
    end
  end
  return nil
end

---@param lines string[]
---@return string[]
function M.filter_combined_diffs(lines)
  local result = {}
  local skip = false
  for _, line in ipairs(lines) do
    if line:match('^diff %-%-cc ') then
      skip = true
    elseif line:match('^diff %-%-git ') then
      skip = false
    end
    if not skip then
      table.insert(result, line)
    end
  end
  return result
end

---@param diff_spec diffs.DiffSpec
---@return string
local function gdiff_buffer_label(diff_spec)
  diff_spec = diffspec.new(diff_spec)
  local left = diff_spec.left
  local right = diff_spec.right

  if
    left.kind == diffspec.endpoint_kind.index and right.kind == diffspec.endpoint_kind.worktree
  then
    return 'unstaged'
  end

  if
    left.kind == diffspec.endpoint_kind.tree
    and left.rev == 'HEAD'
    and right.kind == diffspec.endpoint_kind.index
  then
    return 'staged'
  end

  if left.kind == diffspec.endpoint_kind.tree and right.kind == diffspec.endpoint_kind.worktree then
    return left.rev
  end

  return diffspec.label(diff_spec)
end

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
---@param diff_spec diffs.DiffSpec
local function set_diff_spec_var(bufnr, diff_spec)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_spec', diffspec.new(diff_spec))
end

---@param bufnr integer
---@param diff_lines string[]
---@param diff_spec diffs.DiffSpec
local function set_diff_hunks_var(bufnr, diff_lines, diff_spec)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_hunks', hunk_model.parse(diff_lines, diff_spec))
end

---@param bufnr integer
local function clear_diff_hunks_var(bufnr)
  pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_hunks')
end

---@param bufnr integer
---@return diffs.DiffSpec?, string?
local function get_diff_spec_var(bufnr)
  local raw = get_buf_var(bufnr, 'diffs_spec')
  if raw == nil then
    return nil, nil
  end

  local ok, parsed = pcall(diffspec.new, raw)
  if not ok then
    return nil, tostring(parsed)
  end

  return parsed, nil
end

---@param raw_lines string[]
---@param repo_root string
---@return string[]
local function replace_combined_diffs(raw_lines, repo_root)
  local unmerged_files = {}
  for _, line in ipairs(raw_lines) do
    local cc_file = line:match('^diff %-%-cc (.+)$')
    if cc_file then
      table.insert(unmerged_files, cc_file)
    end
  end

  local result = M.filter_combined_diffs(raw_lines)

  for _, filename in ipairs(unmerged_files) do
    local filepath = repo_root .. '/' .. filename
    local old_lines = git.get_file_content(':2', filepath) or {}
    local new_lines = git.get_file_content(':3', filepath) or {}
    local diff_lines = render.unified_lines(old_lines, new_lines, filename, filename)
    for _, dl in ipairs(diff_lines) do
      table.insert(result, dl)
    end
  end

  return result
end

---@param args? string
---@param vertical? boolean
function M.gdiff(args, vertical)
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)

  if filepath == '' then
    vim.notify('[diffs.nvim]: cannot diff unnamed buffer', vim.log.levels.ERROR)
    return
  end

  local rel_path = git.get_relative_path(filepath)
  if not rel_path then
    vim.notify('[diffs.nvim]: not in a git repository', vim.log.levels.ERROR)
    return
  end

  local parsed, parse_err = gdiff_parser.parse(args, {
    path = rel_path,
    current = diffspec.worktree(),
  })
  if not parsed then
    vim.notify('[diffs.nvim]: ' .. parse_err, vim.log.levels.ERROR)
    return
  end

  if parsed.novertical then
    vertical = false
  end

  local diff_spec = parsed.spec
  local diff_label = gdiff_buffer_label(diff_spec)
  local diff_path = diff_spec.scope.path
  local repo_root = git.get_repo_root(filepath)
  if not repo_root then
    vim.notify('[diffs.nvim]: not in a git repository', vim.log.levels.ERROR)
    return
  end

  local diff_lines, render_err = render.file(diff_spec, repo_root, {
    worktree_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
  })
  if not diff_lines then
    vim.notify('[diffs.nvim]: ' .. (render_err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  if #diff_lines == 0 then
    vim.notify('[diffs.nvim]: no changes for ' .. diffspec.label(diff_spec), vim.log.levels.INFO)
    return
  end

  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = diff_buf })
  vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = diff_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = diff_buf })
  vim.api.nvim_buf_set_name(diff_buf, 'diffs://' .. diff_label .. ':' .. diff_path)
  set_diff_spec_var(diff_buf, diff_spec)
  set_diff_hunks_var(diff_buf, diff_lines, diff_spec)
  if repo_root then
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_repo_root', repo_root)
  end

  local existing_win = M.find_diffs_window()
  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
    vim.api.nvim_win_set_buf(existing_win, diff_buf)
  else
    vim.cmd(vertical and 'vsplit' or 'split')
    vim.api.nvim_win_set_buf(0, diff_buf)
  end

  M.setup_diff_buf(diff_buf)
  dbg('opened diff buffer %d for %s (%s)', diff_buf, diff_path, diffspec.label(diff_spec))

  vim.schedule(function()
    runtime.attach(diff_buf)
  end)
end

---@class diffs.GdiffFileOpts
---@field vertical? boolean
---@field staged? boolean
---@field untracked? boolean
---@field unmerged? boolean
---@field old_filepath? string
---@field hunk_position? { hunk_header: string, offset: integer }

---@param filepath string
---@param opts? diffs.GdiffFileOpts
function M.gdiff_file(filepath, opts)
  opts = opts or {}

  local rel_path = git.get_relative_path(filepath)
  if not rel_path then
    vim.notify('[diffs.nvim]: not in a git repository', vim.log.levels.ERROR)
    return
  end

  local old_rel_path = opts.old_filepath and git.get_relative_path(opts.old_filepath) or rel_path

  local old_lines, new_lines, err
  local diff_label

  if opts.unmerged then
    old_lines = git.get_file_content(':2', filepath)
    if not old_lines then
      old_lines = {}
    end
    new_lines = git.get_file_content(':3', filepath)
    if not new_lines then
      new_lines = {}
    end
    diff_label = 'unmerged'
  elseif opts.untracked then
    old_lines = {}
    new_lines, err = git.get_working_content(filepath)
    if not new_lines then
      vim.notify('[diffs.nvim]: ' .. (err or 'cannot read file'), vim.log.levels.ERROR)
      return
    end
    diff_label = 'untracked'
  elseif opts.staged then
    old_lines, err = git.get_file_content('HEAD', opts.old_filepath or filepath)
    if not old_lines then
      old_lines = {}
    end
    new_lines, err = git.get_index_content(filepath)
    if not new_lines then
      new_lines = {}
    end
    diff_label = 'staged'
  else
    old_lines, err = git.get_index_content(opts.old_filepath or filepath)
    if not old_lines then
      old_lines, err = git.get_file_content('HEAD', opts.old_filepath or filepath)
      if not old_lines then
        old_lines = {}
        diff_label = 'untracked'
      else
        diff_label = 'unstaged'
      end
    else
      diff_label = 'unstaged'
    end
    new_lines, err = git.get_working_content(filepath)
    if not new_lines then
      new_lines = {}
    end
  end

  local diff_lines = render.unified_lines(old_lines, new_lines, old_rel_path, rel_path)

  if #diff_lines == 0 then
    vim.notify('[diffs.nvim]: no changes', vim.log.levels.INFO)
    return
  end

  local repo_root = git.get_repo_root(filepath)

  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = diff_buf })
  vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = diff_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = diff_buf })
  vim.api.nvim_buf_set_name(diff_buf, 'diffs://' .. diff_label .. ':' .. rel_path)
  if repo_root then
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_repo_root', repo_root)
  end
  if old_rel_path ~= rel_path then
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_old_filepath', old_rel_path)
  end

  local existing_win = M.find_diffs_window()
  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
    vim.api.nvim_win_set_buf(existing_win, diff_buf)
  else
    vim.cmd(opts.vertical and 'vsplit' or 'split')
    vim.api.nvim_win_set_buf(0, diff_buf)
  end

  if opts.hunk_position then
    local target_line = M.find_hunk_line(diff_lines, opts.hunk_position)
    if target_line then
      vim.api.nvim_win_set_cursor(0, { target_line, 0 })
      dbg('jumped to line %d for hunk', target_line)
    end
  end

  M.setup_diff_buf(diff_buf)

  if diff_label == 'unmerged' then
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_unmerged', true)
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_working_path', filepath)
    local conflict_config = runtime.get_conflict_config()
    require('diffs.merge').setup_keymaps(diff_buf, conflict_config)
  end

  dbg('opened diff buffer %d for %s (%s)', diff_buf, rel_path, diff_label)

  vim.schedule(function()
    runtime.attach(diff_buf)
  end)
end

---@class diffs.GdiffSectionOpts
---@field vertical? boolean
---@field staged? boolean

---@param repo_root string
---@param opts? diffs.GdiffSectionOpts
function M.gdiff_section(repo_root, opts)
  opts = opts or {}

  local cmd = { 'git', '-C', repo_root, 'diff', '--no-ext-diff', '--no-color' }
  if opts.staged then
    table.insert(cmd, '--cached')
  end

  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify('[diffs.nvim]: git diff failed', vim.log.levels.ERROR)
    return
  end

  result = replace_combined_diffs(result, repo_root)

  if #result == 0 then
    vim.notify('[diffs.nvim]: no changes in section', vim.log.levels.INFO)
    return
  end

  local diff_label = opts.staged and 'staged' or 'unstaged'
  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, result)
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = diff_buf })
  vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = diff_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = diff_buf })
  vim.api.nvim_buf_set_name(diff_buf, 'diffs://' .. diff_label .. ':all')
  vim.api.nvim_buf_set_var(diff_buf, 'diffs_repo_root', repo_root)

  local existing_win = M.find_diffs_window()
  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
    vim.api.nvim_win_set_buf(existing_win, diff_buf)
  else
    vim.cmd(opts.vertical and 'vsplit' or 'split')
    vim.api.nvim_win_set_buf(0, diff_buf)
  end

  M.setup_diff_buf(diff_buf)
  dbg('opened section diff buffer %d (%s)', diff_buf, diff_label)

  vim.schedule(function()
    runtime.attach(diff_buf)
  end)
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

---@param arg? string
---@return diffs.GreviewSpec?, string?
local function parse_review_arg(arg)
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
local function normalize_greview(spec, repo_root_override)
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
local function build_review_cmd(review)
  local cmd = { 'git', '-C', review.repo_root, 'diff', '--no-ext-diff', '--no-color' }
  vim.list_extend(cmd, review.exec_args)
  return cmd
end

---@param review diffs.NormalizedGreview
---@return string
local function review_buffer_name(review)
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
local function complete_greview(arglead)
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
---@return string[]?, string?
local function run_review(review)
  local result = vim.fn.systemlist(build_review_cmd(review))
  if vim.v.shell_error ~= 0 then
    return nil, 'git diff failed'
  end
  return replace_combined_diffs(result, review.repo_root), nil
end

---@param spec? diffs.GreviewSpec
---@return integer?
function M.greview(spec)
  local review, err = normalize_greview(spec)
  if not review then
    vim.notify('[diffs.nvim]: ' .. err, vim.log.levels.ERROR)
    return nil
  end

  local target_name = review_buffer_name(review)
  local existing_buf = vim.fn.bufnr(target_name)
  if existing_buf ~= -1 then
    pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
  end

  local result, diff_err = run_review(review)
  if not result then
    vim.notify('[diffs.nvim]: ' .. diff_err, vim.log.levels.ERROR)
    return nil
  end
  if #result == 0 then
    vim.notify('[diffs.nvim]: no diff against ' .. review.display, vim.log.levels.INFO)
    return nil
  end

  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, result)
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = diff_buf })
  vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = diff_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = diff_buf })
  vim.api.nvim_buf_set_name(diff_buf, target_name)
  vim.api.nvim_buf_set_var(diff_buf, 'diffs_repo_root', review.repo_root)
  vim.api.nvim_buf_set_var(diff_buf, 'diffs_review_base', review.base)
  if review.target then
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_review_target', review.target)
  end
  if review.mode then
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_review_mode', review.mode)
  end

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

  vim.fn.setqflist({}, ' ', {
    title = 'review: ' .. review.display,
    items = qf_items,
    quickfixtextfunc = 'v:lua._diffs_qftf',
  })

  local existing_win = M.find_diffs_window()
  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
    vim.api.nvim_win_set_buf(existing_win, diff_buf)
  else
    vim.cmd(review.vertical and 'vsplit' or 'split')
    vim.api.nvim_win_set_buf(0, diff_buf)
  end

  vim.fn.setloclist(0, {}, ' ', {
    title = 'review hunks: ' .. review.display,
    items = loc_items,
    quickfixtextfunc = 'v:lua._diffs_qftf',
  })

  M.setup_diff_buf(diff_buf)
  dbg('opened review buffer %d (%s)', diff_buf, review.display)

  vim.schedule(function()
    runtime.attach(diff_buf)
  end)

  return diff_buf
end

---@param buf integer
---@param lnum integer
---@return string?
function M.review_file_at_line(buf, lnum)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, lnum, false)
  for i = #lines, 1, -1 do
    local file = lines[i]:match('^diff %-%-git a/.+ b/(.+)$')
    if file then
      return file
    end
  end
  return nil
end

---@param bufnr integer
function M.read_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local url_body = name:match('^diffs://(.+)$')
  if not url_body then
    return
  end

  local repo_root = get_buf_var(bufnr, 'diffs_repo_root')
  if not repo_root then
    vim.notify(
      '[diffs.nvim]: cannot reload diffs:// buffer without diffs_repo_root',
      vim.log.levels.WARN
    )
    return
  end

  local diff_lines
  local stored_spec, spec_err = get_diff_spec_var(bufnr)
  if spec_err then
    vim.notify(
      '[diffs.nvim]: invalid diffs_spec metadata: ' .. tostring(spec_err),
      vim.log.levels.WARN
    )
    return
  end

  local label, path
  if stored_spec then
    local read_err
    diff_lines, read_err = render.file(stored_spec, repo_root, { empty_on_missing = true })
    if not diff_lines then
      vim.notify('[diffs.nvim]: ' .. read_err, vim.log.levels.WARN)
      return
    end
  else
    label, path = url_body:match('^([^:]+):(.+)$')
    if not label or not path then
      vim.notify(
        '[diffs.nvim]: cannot reload malformed diffs:// buffer: ' .. name,
        vim.log.levels.WARN
      )
      return
    end
  end

  if not stored_spec and path == 'all' then
    local cmd = { 'git', '-C', repo_root, 'diff', '--no-ext-diff', '--no-color' }
    if label == 'staged' then
      table.insert(cmd, '--cached')
    end
    diff_lines = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
      diff_lines = {}
    end

    diff_lines = replace_combined_diffs(diff_lines, repo_root)
  elseif not stored_spec and label == 'review' then
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
      review_spec = select(1, parse_review_arg(path))
    end

    if review_spec then
      local review = select(1, normalize_greview(review_spec, repo_root))
      if review then
        diff_lines = vim.fn.systemlist(build_review_cmd(review))
        if vim.v.shell_error ~= 0 then
          diff_lines = {}
        else
          diff_lines = replace_combined_diffs(diff_lines, repo_root)
        end
      else
        diff_lines = {}
      end
    else
      diff_lines = {}
    end
  elseif not stored_spec then
    local abs_path = repo_root .. '/' .. path

    local old_ok, old_rel_path = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_old_filepath')
    local old_abs_path = old_ok and old_rel_path and (repo_root .. '/' .. old_rel_path) or abs_path
    local old_name = old_ok and old_rel_path or path

    local old_lines, new_lines

    if label == 'unmerged' then
      old_lines = git.get_file_content(':2', abs_path) or {}
      new_lines = git.get_file_content(':3', abs_path) or {}
    elseif label == 'untracked' then
      old_lines = {}
      new_lines = git.get_working_content(abs_path) or {}
    elseif label == 'staged' then
      old_lines = git.get_file_content('HEAD', old_abs_path) or {}
      new_lines = git.get_index_content(abs_path) or {}
    elseif label == 'unstaged' then
      old_lines = git.get_index_content(old_abs_path)
      if not old_lines then
        old_lines = git.get_file_content('HEAD', old_abs_path) or {}
      end
      new_lines = git.get_working_content(abs_path) or {}
    else
      old_lines = git.get_file_content(label, abs_path) or {}
      new_lines = git.get_working_content(abs_path) or {}
    end

    diff_lines = render.unified_lines(old_lines, new_lines, old_name, path)
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, diff_lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = bufnr })
  if stored_spec then
    set_diff_hunks_var(bufnr, diff_lines, stored_spec)
  else
    clear_diff_hunks_var(bufnr)
  end
  M.setup_diff_buf(bufnr)

  local debug_label = stored_spec and diffspec.label(stored_spec)
    or ((label or '?') .. ':' .. (path or '?'))
  dbg('reloaded diff buffer %d (%s)', bufnr, debug_label)

  runtime.attach(bufnr)
end

function M.setup()
  vim.api.nvim_create_user_command('Gdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, false)
  end, {
    nargs = '*',
    desc = 'Show unified diff against a Fugitive object',
  })

  vim.api.nvim_create_user_command('Gvdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, true)
  end, {
    nargs = '*',
    desc = 'Show unified diff against a Fugitive object in vertical split',
  })

  vim.api.nvim_create_user_command('Ghdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, false)
  end, {
    nargs = '*',
    desc = 'Show unified diff against a Fugitive object in horizontal split',
  })

  vim.api.nvim_create_user_command('Greview', function(opts)
    local spec, err = parse_review_arg(opts.args ~= '' and opts.args or nil)
    if not spec then
      vim.notify('[diffs.nvim]: ' .. err, vim.log.levels.ERROR)
      return
    end
    M.greview(spec)
  end, {
    nargs = '?',
    complete = complete_greview,
    desc = 'Review the repo against the default branch or a git review spec',
  })
end

M._test = {
  complete_greview = complete_greview,
  gdiff_buffer_label = gdiff_buffer_label,
  normalize_greview = normalize_greview,
  parse_review_arg = parse_review_arg,
}

return M
