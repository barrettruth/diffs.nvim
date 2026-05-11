local M = {}

local actions = require('diffs.actions')
local content = require('diffs.content')
local diffspec = require('diffs.spec')
local gdiff_parser = require('diffs.gdiff')
local git = require('diffs.git')
local hunk_model = require('diffs.hunks')
local lists = require('diffs.lists')
local log = require('diffs.log')
local rails = require('diffs.rails')
local render = require('diffs.render')
local review = require('diffs.review')
local runtime = require('diffs.runtime')
local split = require('diffs.split')

local dbg = log.dbg
local notify = log.notify
local greview_follow_group = vim.api.nvim_create_augroup('diffs_greview_follow', { clear = false })

---@class diffs.HunkKeymap
---@field mode string
---@field lhs string
---@field callback function

---@type table<integer, diffs.HunkKeymap[]>
local hunk_keymaps = {}
---@type table<integer, integer>
local hunk_keymap_autocmds = {}

---@class diffs.GreviewFollowState
---@field left_buf integer
---@field right_buf integer
---@field file string
---@field key string
---@field hunk_index? integer
---@field autocmds integer[]
---@field pending? boolean
---@field pending_item? table

---@type table<integer, diffs.GreviewFollowState>
local greview_follow_states = {}

---@param bufnr integer
---@param mode string
---@param lhs string
---@return table?
local function get_buffer_keymap(bufnr, mode, lhs)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
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
  for _, keymap in ipairs(registered) do
    local current = get_buffer_keymap(bufnr, keymap.mode, keymap.lhs)
    if current and current.callback == keymap.callback then
      pcall(vim.keymap.del, keymap.mode, keymap.lhs, { buffer = bufnr })
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
---@param mode string
---@param lhs string
---@param callback function
---@param desc string
local function set_hunk_keymap(bufnr, mode, lhs, callback, desc)
  if get_buffer_keymap(bufnr, mode, lhs) then
    return
  end

  vim.keymap.set(mode, lhs, callback, { buffer = bufnr, desc = desc })
  hunk_keymaps[bufnr] = hunk_keymaps[bufnr] or {}
  hunk_keymaps[bufnr][#hunk_keymaps[bufnr] + 1] = {
    mode = mode,
    lhs = lhs,
    callback = callback,
  }
end

---@param bufnr integer
---@return integer, integer
local function visual_range(bufnr)
  local start_line = vim.api.nvim_buf_get_mark(bufnr, '<')[1]
  local finish_line = vim.api.nvim_buf_get_mark(bufnr, '>')[1]
  return math.min(start_line, finish_line), math.max(start_line, finish_line)
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
---@return integer?
local function first_window_for_buffer(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

---@param bufnr integer
function M.setup_diff_buf(bufnr)
  vim.diagnostic.enable(false, { bufnr = bufnr })
  if not get_buffer_keymap(bufnr, 'n', 'q') then
    vim.keymap.set('n', 'q', '<cmd>close<CR>', { buffer = bufnr })
  end
  local has_hunks, parsed_hunks = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_hunks')
  if not has_hunks then
    clear_hunk_keymaps(bufnr)
    return
  end

  clear_hunk_keymaps(bufnr)
  local can_put = false
  local can_obtain = false
  for _, hunk in ipairs(type(parsed_hunks) == 'table' and parsed_hunks or {}) do
    can_put = can_put or hunk.can_put == true
    can_obtain = can_obtain or hunk.can_obtain == true
  end

  set_hunk_keymap(bufnr, 'n', ']c', function()
    hunk_model.goto_next(bufnr)
  end, 'Next diff hunk')
  set_hunk_keymap(bufnr, 'n', '[c', function()
    hunk_model.goto_prev(bufnr)
  end, 'Previous diff hunk')
  set_hunk_keymap(bufnr, 'n', '<CR>', function()
    hunk_model.open_source(bufnr)
  end, 'Open source file')
  if can_obtain then
    set_hunk_keymap(bufnr, 'n', 'do', function()
      if actions.obtain_hunk(bufnr) then
        M.read_buffer(bufnr)
      end
    end, 'Unstage Gdiff hunk')
    set_hunk_keymap(bufnr, 'x', 'do', function()
      local range_start, range_finish = visual_range(bufnr)
      if actions.obtain_range(bufnr, range_start, range_finish) then
        M.read_buffer(bufnr)
      end
    end, 'Unstage selected Gdiff lines')
  end
  if can_put then
    set_hunk_keymap(bufnr, 'n', 'dp', function()
      if actions.put_hunk(bufnr) then
        M.read_buffer(bufnr)
      end
    end, 'Stage Gdiff hunk')
    set_hunk_keymap(bufnr, 'x', 'dp', function()
      local range_start, range_finish = visual_range(bufnr)
      if actions.put_range(bufnr, range_start, range_finish) then
        M.read_buffer(bufnr)
      end
    end, 'Stage selected Gdiff lines')
  end

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
---@param info diffs.RailInfo?
local function set_diff_rails_var(bufnr, info)
  if info then
    vim.api.nvim_buf_set_var(bufnr, 'diffs_rail_width', info.prefix_width)
  else
    pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_rail_width')
  end
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

---@param source table
---@return diffs.GeneratedBufferSource?
local function normalize_source(source)
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
local function get_source_var(bufnr)
  local raw = get_buf_var(bufnr, 'diffs_source')
  if raw == nil then
    return nil, nil
  end

  local ok, source = pcall(normalize_source, raw)
  if not ok then
    return nil, tostring(source)
  end

  return source, nil
end

---@param bufnr integer
local function set_generated_diff_buffer_options(bufnr)
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = bufnr })
end

---@param win integer
local function clear_generated_diff_window_bindings(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end

  vim.api.nvim_set_option_value('scrollbind', false, { win = win })
  vim.api.nvim_set_option_value('cursorbind', false, { win = win })
end

---@class diffs.GeneratedDiffBufferOpts
---@field name string
---@field lines string[]
---@field repo_root? string
---@field diff_spec? diffs.DiffSpec
---@field source? diffs.GeneratedBufferSource
---@field vars? table<string, any>

---@param opts diffs.GeneratedDiffBufferOpts
---@return integer
local function create_generated_diff_buffer(opts)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local display_lines, rail_info = rails.annotate(opts.lines)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, display_lines)
  set_generated_diff_buffer_options(bufnr)
  vim.api.nvim_buf_set_name(bufnr, opts.name)
  set_diff_rails_var(bufnr, rail_info)

  if opts.diff_spec then
    set_diff_spec_var(bufnr, opts.diff_spec)
    set_diff_hunks_var(bufnr, opts.lines, opts.diff_spec)
  end
  if opts.repo_root then
    vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', opts.repo_root)
  end
  if opts.source then
    vim.api.nvim_buf_set_var(bufnr, 'diffs_source', opts.source)
  end
  for name, value in pairs(opts.vars or {}) do
    if value ~= nil then
      vim.api.nvim_buf_set_var(bufnr, name, value)
    end
  end

  return bufnr
end

---@param bufnr integer
---@param vertical? boolean
local function show_generated_diff_buffer(bufnr, vertical)
  local existing_win = M.find_diffs_window()
  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
    split.release_pair_window_options(existing_win)
    clear_generated_diff_window_bindings(existing_win)
    vim.api.nvim_win_set_buf(existing_win, bufnr)
  else
    vim.cmd(vertical and 'vsplit' or 'split')
    clear_generated_diff_window_bindings(vim.api.nvim_get_current_win())
    vim.api.nvim_win_set_buf(0, bufnr)
  end
end

---@param bufnr integer
---@param diff_lines string[]
---@param diff_spec? diffs.DiffSpec
local function replace_generated_diff_buffer_lines(bufnr, diff_lines, diff_spec)
  local display_lines, rail_info = rails.annotate(diff_lines)
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, display_lines)
  set_generated_diff_buffer_options(bufnr)
  set_diff_rails_var(bufnr, rail_info)

  if diff_spec then
    set_diff_hunks_var(bufnr, diff_lines, diff_spec)
  else
    clear_diff_hunks_var(bufnr)
  end
end

---@param bufnr integer
local function attach_generated_diff_buffer(bufnr)
  M.setup_diff_buf(bufnr)

  vim.schedule(function()
    runtime.attach(bufnr)
  end)
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

---@return diffs.ReviewDeps
local function review_deps()
  return {
    create_generated_diff_buffer = create_generated_diff_buffer,
    show_generated_diff_buffer = show_generated_diff_buffer,
    attach_generated_diff_buffer = attach_generated_diff_buffer,
    replace_combined_diffs = replace_combined_diffs,
  }
end

---@param repo_root string
---@param section "staged"|"unstaged"
---@return string[]
local function render_section_source(repo_root, section)
  local cmd = { 'git', '-C', repo_root, 'diff', '--no-ext-diff', '--no-color' }
  if section == 'staged' then
    table.insert(cmd, '--cached')
  end

  local diff_lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    diff_lines = {}
  end

  return replace_combined_diffs(diff_lines, repo_root)
end

---@param source diffs.GeneratedBufferSource
---@return string[]?, diffs.DiffSpec?, string?, table?
local function render_source(source)
  if source.kind == 'file' then
    local diff_lines, read_err = render.file(source.spec, source.repo_root, {
      empty_on_missing = true,
    })
    if not diff_lines then
      return nil, nil, read_err, nil
    end
    return diff_lines, source.spec, diffspec.label(source.spec), nil
  end

  if source.kind == 'file_pair' then
    local abs_path = source.repo_root .. '/' .. source.path
    local old_abs_path = source.repo_root .. '/' .. source.old_path
    local old_lines, new_lines
    if source.edge == 'staged' then
      old_lines = git.get_file_content('HEAD', old_abs_path) or {}
      new_lines = git.get_index_content(abs_path) or {}
    else
      old_lines = git.get_index_content(old_abs_path)
      if not old_lines then
        old_lines = git.get_file_content('HEAD', old_abs_path) or {}
      end
      new_lines = git.get_working_content(abs_path) or {}
    end
    return render.unified_lines(old_lines, new_lines, source.old_path, source.path),
      nil,
      source.edge .. ':' .. source.path,
      nil
  end

  if source.kind == 'section' then
    return render_section_source(source.repo_root, source.section),
      nil,
      source.section .. ':all',
      nil
  end

  if source.kind == 'review' then
    local review_lines, review_err, list_opts = review.reload_source(source, review_deps())
    if not review_lines then
      return nil, nil, review_err, nil
    end
    return review_lines, nil, 'review', list_opts
  end

  local abs_path = source.repo_root .. '/' .. source.path
  local old_lines = git.get_file_content(':2', abs_path) or {}
  local new_lines = git.get_file_content(':3', abs_path) or {}
  return render.unified_lines(old_lines, new_lines, source.path, source.path),
    nil,
    'unmerged:' .. source.path,
    nil
end

---@param diff_label string
---@param rel_path string
---@param old_rel_path string
---@return string
local function file_pair_label(diff_label, rel_path, old_rel_path)
  return diff_label .. ' rename/copy ' .. old_rel_path .. ' -> ' .. rel_path
end

---@param spec? diffs.GreviewSpec
---@return integer?
function M.greview(spec)
  return review.greview(spec, review_deps())
end

---@param buf integer
---@param lnum integer
---@return string?
function M.review_file_at_line(buf, lnum)
  return review.file_at_line(buf, lnum)
end

local layout_options = {
  '++layout=unified',
  '++layout=split',
}

local gdiff_objects = {
  ':',
  ':%',
  ':0:%',
  '@:%',
}

local command_names = {
  Gdiff = true,
  Gvdiff = true,
  Ghdiff = true,
  Greview = true,
}

---@param value string
---@param prefix string
---@return boolean
local function starts_with(value, prefix)
  return value:find(prefix, 1, true) == 1
end

---@param candidates string[]
---@param arglead string
---@return string[]
local function prefix_matches(candidates, arglead)
  local matches = {}
  for _, candidate in ipairs(candidates) do
    if starts_with(candidate, arglead) then
      matches[#matches + 1] = candidate
    end
  end
  return matches
end

---@param arglead string
---@return string[]
local function complete_gdiff_object(arglead)
  local matches = prefix_matches(gdiff_objects, arglead)
  for _, ref in ipairs(review.complete(arglead)) do
    if not ref:find('..', 1, true) then
      matches[#matches + 1] = ref
    end
  end
  return matches
end

---@param arglead string
---@param cmdline? string
---@param cursorpos? integer
---@return { has_layout: boolean, has_value: boolean }
local function completion_context(arglead, cmdline, cursorpos)
  local before = cmdline or ''
  if type(cursorpos) == 'number' and cursorpos > 0 then
    before = before:sub(1, cursorpos)
  end
  if arglead ~= '' and before:sub(-#arglead) == arglead then
    before = before:sub(1, #before - #arglead)
  end

  local tokens = vim.split(vim.trim(before), '%s+', { trimempty = true })
  local command_index = 0
  for i = #tokens, 1, -1 do
    if command_names[tokens[i]] then
      command_index = i
      break
    end
  end
  if command_index == 0 and #tokens > 0 then
    command_index = 1
  end

  local has_layout = false
  local has_value = false
  for i = command_index + 1, #tokens do
    local token = tokens[i]
    if token:match('^%+%+layout=') then
      has_layout = true
    elseif not token:match('^%+%+') then
      has_value = true
    end
  end
  return {
    has_layout = has_layout,
    has_value = has_value,
  }
end

---@param arglead string
---@param cmdline? string
---@param cursorpos? integer
---@return string[]
local function complete_gdiff_command(arglead, cmdline, cursorpos)
  local context = completion_context(arglead, cmdline, cursorpos)
  if context.has_value then
    return {}
  end
  if arglead:match('^%+%+') then
    if context.has_layout then
      return {}
    end
    return prefix_matches(layout_options, arglead)
  end
  local matches = {}
  if arglead == '' and not context.has_layout then
    vim.list_extend(matches, layout_options)
  end
  vim.list_extend(matches, complete_gdiff_object(arglead))
  return matches
end

---@param arglead string
---@param cmdline? string
---@param cursorpos? integer
---@return string[]
local function complete_gdiff_split_command(arglead, cmdline, cursorpos)
  local context = completion_context(arglead, cmdline, cursorpos)
  if context.has_value or arglead:match('^%+%+') then
    return {}
  end
  return complete_gdiff_object(arglead)
end

---@param arglead string
---@param cmdline? string
---@param cursorpos? integer
---@return string[]
local function complete_greview_command(arglead, cmdline, cursorpos)
  local context = completion_context(arglead, cmdline, cursorpos)
  if context.has_value then
    return {}
  end
  if arglead:match('^%+%+') then
    local matches = {}
    if not context.has_layout then
      vim.list_extend(matches, prefix_matches(layout_options, arglead))
    end
    vim.list_extend(matches, review.complete(arglead))
    return matches
  end
  local matches = {}
  if arglead == '' and not context.has_layout then
    vim.list_extend(matches, layout_options)
  end
  vim.list_extend(matches, review.complete(arglead))
  return matches
end

---@param args? string
---@return integer?
function M.greview_command(args)
  local parsed, err = review.parse_command_args(args)
  if not parsed then
    notify(err, vim.log.levels.ERROR)
    return nil
  end

  local bufnr = M.greview(parsed.spec)
  if bufnr and parsed.layout == 'split' then
    M.greview_split({ bufnr = bufnr, lnum = 1 })
  end
  return bufnr
end

---@param repo_root string
---@param path string
---@return string?
local function filetype_for_path(repo_root, path)
  local filepath = repo_root .. '/' .. path
  local existing_buf = vim.fn.bufnr(filepath)
  if existing_buf ~= -1 then
    local ft = vim.api.nvim_get_option_value('filetype', { buf = existing_buf })
    if ft and ft ~= '' then
      return ft
    end
  end

  local ft = vim.filetype.match({ filename = path })
  if ft and ft ~= '' then
    return ft
  end
  return nil
end

---@param win integer?
local function restore_window(win)
  if type(win) == 'number' and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
end

---@param review_buf integer
local function stop_greview_follow(review_buf)
  local state = greview_follow_states[review_buf]
  if state then
    for _, id in ipairs(state.autocmds or {}) do
      pcall(vim.api.nvim_del_autocmd, id)
    end
  end
  greview_follow_states[review_buf] = nil
  if vim.api.nvim_buf_is_valid(review_buf) then
    pcall(vim.api.nvim_buf_del_var, review_buf, 'diffs_review_split_buf')
  end
end

---@param review_buf integer
---@return integer?
local function stored_greview_pair_buf(review_buf)
  local state = greview_follow_states[review_buf]
  if state then
    return state.right_buf
  end

  local previous = get_buf_var(review_buf, 'diffs_review_split_buf')
  if type(previous) == 'number' then
    return previous
  end
  return nil
end

---@param review_buf integer
local function close_owned_greview_pair(review_buf)
  local previous = stored_greview_pair_buf(review_buf)
  stop_greview_follow(review_buf)
  if type(previous) == 'number' and vim.api.nvim_buf_is_valid(previous) then
    split.close_pair(previous)
  end
end

---@param state diffs.GreviewFollowState?
---@return boolean
local function greview_pair_valid(state)
  if
    not state
    or not vim.api.nvim_buf_is_valid(state.left_buf)
    or not vim.api.nvim_buf_is_valid(state.right_buf)
  then
    return false
  end

  return get_buf_var(state.left_buf, 'diffs_split_peer') == state.right_buf
    and get_buf_var(state.right_buf, 'diffs_split_peer') == state.left_buf
end

---@class diffs.GreviewSplitOpts
---@field bufnr? integer
---@field lnum? integer
---@field item? table

---@class diffs.GreviewSplitContext
---@field review_buf integer
---@field selected diffs.GeneratedFileSelection
---@field diff_spec diffs.DiffSpec
---@field repo_root string
---@field diff_lines string[]

---@param opts? diffs.GreviewSplitOpts
---@return diffs.GreviewSplitContext?, string?, integer?, integer?
local function greview_split_context(opts)
  opts = opts or {}

  ---@type diffs.GeneratedFileSelectionOpts
  local selection_opts = {
    bufnr = opts.bufnr,
    lnum = opts.lnum,
    item = opts.item,
  }
  local selected, select_err = lists.selected_generated_file(selection_opts)
  if not selected then
    return nil, select_err or 'no Greview file selected', vim.log.levels.WARN, nil
  end

  local review_buf = selected.bufnr
  if not vim.api.nvim_buf_is_valid(review_buf) then
    return nil, 'selected Greview buffer is no longer valid', vim.log.levels.WARN, review_buf
  end

  local source, source_err = get_source_var(review_buf)
  if source_err then
    return nil,
      'invalid diffs_source metadata: ' .. tostring(source_err),
      vim.log.levels.WARN,
      review_buf
  end
  if not source or source.kind ~= 'review' then
    return nil, 'selected file is not from a Greview buffer', vim.log.levels.WARN, nil
  end

  local diff_spec, normalized, spec_err =
    review.diff_spec_for_file(source.review, source.repo_root, selected.file, selected)
  if not diff_spec then
    return nil, spec_err or 'cannot build Greview split diff spec', vim.log.levels.ERROR, review_buf
  end

  local repo_root = normalized and normalized.repo_root or source.repo_root
  local diff_lines, render_err = render.file(diff_spec, repo_root)
  if not diff_lines then
    return nil, render_err or 'cannot render Greview split file', vim.log.levels.ERROR, review_buf
  end
  if #diff_lines == 0 then
    return nil, 'no changes for ' .. diffspec.label(diff_spec), vim.log.levels.INFO, review_buf
  end

  return {
    review_buf = review_buf,
    selected = selected,
    diff_spec = diff_spec,
    repo_root = repo_root,
    diff_lines = diff_lines,
  },
    nil,
    nil,
    review_buf
end

---@type fun(review_buf: integer, item?: table)
local schedule_greview_follow

local function refresh_greview_jump_callback()
  lists.set_generated_jump_callback(function(item)
    if type(item) == 'table' and type(item.bufnr) == 'number' then
      schedule_greview_follow(item.bufnr, item)
    end
  end)
end

---@param review_buf integer
---@param opened { left_buf: integer, right_buf: integer, left_win: integer, right_win: integer }
---@param selected diffs.GeneratedFileSelection
local function start_greview_follow(review_buf, opened, selected)
  refresh_greview_jump_callback()
  stop_greview_follow(review_buf)

  ---@type diffs.GreviewFollowState
  local state = {
    left_buf = opened.left_buf,
    right_buf = opened.right_buf,
    file = selected.file,
    key = selected.key or selected.file,
    hunk_index = selected.hunk_index,
    autocmds = {},
  }
  greview_follow_states[review_buf] = state
  vim.api.nvim_buf_set_var(review_buf, 'diffs_review_split_buf', opened.right_buf)

  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorMoved' }, {
    group = greview_follow_group,
    buffer = review_buf,
    callback = function(args)
      if get_buf_var(args.buf, 'diffs_generated_jump_in_progress') then
        return
      end
      schedule_greview_follow(args.buf)
    end,
  })
  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
    group = greview_follow_group,
    buffer = review_buf,
    once = true,
    callback = function(args)
      stop_greview_follow(args.buf)
    end,
  })

  local function stop_if_owned_pair(args)
    local current = greview_follow_states[review_buf]
    if current and (args.buf == current.left_buf or args.buf == current.right_buf) then
      stop_greview_follow(review_buf)
    end
  end

  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
    group = greview_follow_group,
    buffer = opened.left_buf,
    once = true,
    callback = stop_if_owned_pair,
  })
  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
    group = greview_follow_group,
    buffer = opened.right_buf,
    once = true,
    callback = stop_if_owned_pair,
  })
end

---@param context diffs.GreviewSplitContext
---@param opts? { restore_focus?: boolean, restore_win?: integer }
---@return { left_buf: integer, right_buf: integer, left_win: integer, right_win: integer }?, string?, integer?
local function open_greview_split_pair(context, opts)
  opts = opts or {}

  local review_buf = context.review_buf
  local review_win = first_window_for_buffer(review_buf)
  if not review_win then
    return nil, 'cannot open Greview split without a visible review buffer', vim.log.levels.WARN
  end
  split.release_pair_window_options(review_win)
  clear_generated_diff_window_bindings(review_win)

  local previous = stored_greview_pair_buf(review_buf)
  stop_greview_follow(review_buf)
  if type(previous) == 'number' and vim.api.nvim_buf_is_valid(previous) then
    split.close_pair(previous)
  end

  review_win = first_window_for_buffer(review_buf)
  if not review_win then
    return nil, 'cannot open Greview split without a visible review buffer', vim.log.levels.WARN
  end

  local restore_win = opts.restore_win or vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(review_win)
  vim.cmd('belowright split')
  local launcher_win = vim.api.nvim_get_current_win()

  local opened, split_err = split.open({
    spec = context.diff_spec,
    repo_root = context.repo_root,
    filetype = filetype_for_path(context.repo_root, context.selected.file),
    diff_lines = context.diff_lines,
    hunk_index = context.selected.hunk_index,
    quickfix = false,
  })
  if not opened then
    if vim.api.nvim_win_is_valid(launcher_win) then
      pcall(vim.api.nvim_win_close, launcher_win, true)
    end
    restore_window(restore_win)
    return nil, split_err or 'cannot open Greview split', vim.log.levels.ERROR
  end

  start_greview_follow(review_buf, opened, context.selected)
  if opts.restore_focus then
    restore_window(restore_win)
  end
  return opened, nil, nil
end

---@param review_buf integer
---@param item? table
local function follow_greview_selection(review_buf, item)
  local state = greview_follow_states[review_buf]
  if not state then
    return
  end

  if not vim.api.nvim_buf_is_valid(review_buf) or not greview_pair_valid(state) then
    stop_greview_follow(review_buf)
    return
  end

  local restore_win = vim.api.nvim_get_current_win()
  local context = greview_split_context({ bufnr = review_buf, item = item })
  if not context then
    close_owned_greview_pair(review_buf)
    restore_window(restore_win)
    return
  end

  local selected = context.selected
  if (selected.key or selected.file) == (state.key or state.file) then
    if selected.hunk_index then
      if split.move_pair_to_hunk_index(state.right_buf, selected.hunk_index) then
        state.hunk_index = selected.hunk_index
      end
    elseif selected.hunk_index ~= state.hunk_index then
      state.hunk_index = nil
    end
    restore_window(restore_win)
    return
  end

  local opened = open_greview_split_pair(context, {
    restore_focus = true,
    restore_win = restore_win,
  })
  if not opened then
    close_owned_greview_pair(review_buf)
  end
  restore_window(restore_win)
end

schedule_greview_follow = function(review_buf, item)
  local state = greview_follow_states[review_buf]
  if not state then
    return
  end
  state.pending_item = item or state.pending_item
  if state.pending then
    return
  end

  state.pending = true
  vim.schedule(function()
    local current = greview_follow_states[review_buf]
    if not current then
      return
    end
    local pending_item = current.pending_item
    current.pending = false
    current.pending_item = nil
    follow_greview_selection(review_buf, pending_item)
  end)
end

---@param opts? diffs.GreviewSplitOpts
---@return { left_buf: integer, right_buf: integer, left_win: integer, right_win: integer }?
function M.greview_split(opts)
  local restore_win = vim.api.nvim_get_current_win()
  local context, err, level, review_buf = greview_split_context(opts)
  if not context then
    if review_buf then
      close_owned_greview_pair(review_buf)
      restore_window(restore_win)
    end
    notify(err or 'cannot open Greview split', level or vim.log.levels.WARN)
    return nil
  end

  local opened, split_err, split_level = open_greview_split_pair(context, {
    restore_focus = true,
    restore_win = restore_win,
  })
  if not opened then
    restore_window(restore_win)
    notify(split_err or 'cannot open Greview split', split_level or vim.log.levels.ERROR)
    return nil
  end

  return opened
end

---@param args? string
---@param vertical? boolean
function M.gdiff(args, vertical)
  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)

  if filepath == '' then
    notify('cannot diff unnamed buffer', vim.log.levels.ERROR)
    return
  end

  local rel_path = git.get_relative_path(filepath)
  if not rel_path then
    notify('not in a git repository', vim.log.levels.ERROR)
    return
  end

  local parsed, parse_err = gdiff_parser.parse(args, {
    path = rel_path,
    current = diffspec.worktree(),
  })
  if not parsed then
    notify(parse_err, vim.log.levels.ERROR)
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
    notify('not in a git repository', vim.log.levels.ERROR)
    return
  end

  if
    diff_spec.left.kind == diffspec.endpoint_kind.index
    and diff_spec.right.kind == diffspec.endpoint_kind.worktree
    and diff_spec.scope.kind == diffspec.scope_kind.file
    and diff_path == rel_path
    and git.is_unmerged(filepath)
  then
    if parsed.layout == 'split' then
      notify('split Gdiff does not support unmerged files yet', vim.log.levels.ERROR)
      return
    end
    M.gdiff_file(filepath, {
      vertical = vertical,
      unmerged = true,
    })
    return
  end

  local worktree_lines = content.from_buffer(bufnr)
  local diff_lines, render_err = render.file(diff_spec, repo_root, {
    worktree_lines = worktree_lines,
  })
  if not diff_lines then
    notify(render_err or 'unknown error', vim.log.levels.ERROR)
    return
  end

  if #diff_lines == 0 then
    notify('no changes for ' .. diffspec.label(diff_spec), vim.log.levels.INFO)
    return
  end

  if parsed.layout == 'split' then
    local opened, split_err = split.open({
      spec = diff_spec,
      repo_root = repo_root,
      filetype = vim.api.nvim_get_option_value('filetype', { buf = bufnr }),
      worktree_lines = worktree_lines,
      diff_lines = diff_lines,
    })
    if not opened then
      notify(split_err or 'cannot open split Gdiff', vim.log.levels.ERROR)
    end
    return
  end

  local diff_buf = create_generated_diff_buffer({
    name = 'diffs://' .. diff_label .. ':' .. diff_path,
    lines = diff_lines,
    repo_root = repo_root,
    diff_spec = diff_spec,
    source = {
      version = 1,
      kind = 'file',
      repo_root = repo_root,
      spec = diff_spec,
    },
  })
  show_generated_diff_buffer(diff_buf, vertical)
  lists.set_for_unified_buffer(diff_buf, diff_lines, {
    title = 'diff: ' .. diffspec.label(diff_spec),
  })
  attach_generated_diff_buffer(diff_buf)
  dbg('opened diff buffer %d for %s (%s)', diff_buf, diff_path, diffspec.label(diff_spec))
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
    notify('not in a git repository', vim.log.levels.ERROR)
    return
  end

  local repo_root = git.get_repo_root(filepath)
  if not repo_root then
    notify('not in a git repository', vim.log.levels.ERROR)
    return
  end

  local old_rel_path = opts.old_filepath and git.get_relative_path(opts.old_filepath) or rel_path

  local old_lines, new_lines, err, diff_lines
  local diff_label
  local diff_spec

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
    diff_spec = diffspec.index_to_worktree(rel_path)
    diff_label = 'untracked'
    diff_lines, err = render.file(diff_spec, repo_root)
  elseif opts.staged then
    diff_label = 'staged'
    if old_rel_path == rel_path then
      diff_spec = diffspec.head_to_index(rel_path)
      diff_lines, err = render.file(diff_spec, repo_root)
    else
      old_lines = git.get_file_content('HEAD', opts.old_filepath or filepath) or {}
      new_lines = git.get_index_content(filepath) or {}
    end
  else
    diff_label = 'unstaged'
    if old_rel_path == rel_path then
      diff_spec = diffspec.index_to_worktree(rel_path)
      diff_lines, err = render.file(diff_spec, repo_root)
    else
      old_lines = git.get_index_content(opts.old_filepath or filepath)
      if not old_lines then
        old_lines = git.get_file_content('HEAD', opts.old_filepath or filepath) or {}
      end
      new_lines = git.get_working_content(filepath) or {}
    end
  end

  if not diff_lines then
    if err then
      notify(err, vim.log.levels.ERROR)
      return
    end
    diff_lines = render.unified_lines(old_lines or {}, new_lines or {}, old_rel_path, rel_path)
  end

  if #diff_lines == 0 then
    if diff_spec then
      notify('no changes for ' .. diffspec.label(diff_spec), vim.log.levels.INFO)
    elseif opts.unmerged then
      notify('no changes for unmerged file:' .. rel_path, vim.log.levels.INFO)
    else
      notify(
        'no text changes for '
          .. file_pair_label(diff_label, rel_path, old_rel_path)
          .. '; generated hunk actions are unavailable',
        vim.log.levels.INFO
      )
    end
    return
  end

  local source
  if diff_spec then
    source = {
      version = 1,
      kind = 'file',
      repo_root = repo_root,
      spec = diff_spec,
    }
  elseif opts.unmerged then
    source = {
      version = 1,
      kind = 'unmerged',
      repo_root = repo_root,
      path = rel_path,
      working_path = filepath,
    }
  else
    source = {
      version = 1,
      kind = 'file_pair',
      repo_root = repo_root,
      edge = diff_label,
      path = rel_path,
      old_path = old_rel_path,
    }
  end

  local diff_buf = create_generated_diff_buffer({
    name = 'diffs://' .. diff_label .. ':' .. rel_path,
    lines = diff_lines,
    repo_root = repo_root,
    diff_spec = diff_spec,
    source = source,
    vars = {
      diffs_old_filepath = old_rel_path ~= rel_path and old_rel_path or nil,
    },
  })
  show_generated_diff_buffer(diff_buf, opts.vertical)

  if opts.hunk_position then
    local target_line = M.find_hunk_line(diff_lines, opts.hunk_position)
    if target_line then
      vim.api.nvim_win_set_cursor(0, { target_line, 0 })
      dbg('jumped to line %d for hunk', target_line)
    end
  end

  lists.set_for_unified_buffer(diff_buf, diff_lines, {
    title = 'diff: ' .. diff_label .. ':' .. rel_path,
    diff_spec = diff_spec,
  })

  attach_generated_diff_buffer(diff_buf)

  if diff_label == 'unmerged' then
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_unmerged', true)
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_working_path', filepath)
    local conflict_config = runtime.get_conflict_config()
    require('diffs.merge').setup_keymaps(diff_buf, conflict_config)
  end

  dbg('opened diff buffer %d for %s (%s)', diff_buf, rel_path, diff_label)
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
    notify('git diff failed', vim.log.levels.ERROR)
    return
  end

  result = replace_combined_diffs(result, repo_root)

  local diff_label = opts.staged and 'staged' or 'unstaged'
  if #result == 0 then
    notify('no changes in ' .. diff_label .. ' section', vim.log.levels.INFO)
    return
  end

  local diff_buf = create_generated_diff_buffer({
    name = 'diffs://' .. diff_label .. ':all',
    lines = result,
    repo_root = repo_root,
    source = {
      version = 1,
      kind = 'section',
      repo_root = repo_root,
      section = diff_label,
    },
  })
  show_generated_diff_buffer(diff_buf, opts.vertical)
  lists.set_for_unified_buffer(diff_buf, result, {
    title = 'diff: ' .. diff_label .. ':all',
  })
  attach_generated_diff_buffer(diff_buf)
  dbg('opened section diff buffer %d (%s)', diff_buf, diff_label)
end

---@param bufnr integer
function M.read_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local url_body = name:match('^diffs://(.+)$')
  if not url_body then
    return
  end

  local source, source_err = get_source_var(bufnr)
  if source_err then
    notify('invalid diffs_source metadata: ' .. tostring(source_err), vim.log.levels.WARN)
    return
  end

  local repo_root = source and source.repo_root or get_buf_var(bufnr, 'diffs_repo_root')
  if not repo_root then
    notify('cannot reload diffs:// buffer without diffs_repo_root', vim.log.levels.WARN)
    return
  end

  if source and source.kind == 'split_endpoint' then
    local ok, err = split.read_buffer(bufnr, source)
    if not ok then
      notify(err or 'cannot reload split diffs:// buffer', vim.log.levels.WARN)
    end
    return
  end

  local diff_lines
  local stored_spec
  local debug_label
  local list_opts
  local label, path

  if source then
    local render_err
    diff_lines, stored_spec, render_err, list_opts = render_source(source)
    if not diff_lines then
      notify(render_err or 'cannot reload diffs:// buffer', vim.log.levels.WARN)
      return
    end
    debug_label = render_err
  else
    local spec_err
    stored_spec, spec_err = get_diff_spec_var(bufnr)
    if spec_err then
      notify('invalid diffs_spec metadata: ' .. tostring(spec_err), vim.log.levels.WARN)
      return
    end

    if stored_spec then
      local read_err
      diff_lines, read_err = render.file(stored_spec, repo_root, { empty_on_missing = true })
      if not diff_lines then
        notify(read_err, vim.log.levels.WARN)
        return
      end
      debug_label = diffspec.label(stored_spec)
    else
      label, path = url_body:match('^([^:]+):(.+)$')
      if not label or not path then
        notify('cannot reload malformed diffs:// buffer: ' .. name, vim.log.levels.WARN)
        return
      end
    end

    if not stored_spec and path == 'all' then
      diff_lines = render_section_source(repo_root, label)
    elseif not stored_spec and label == 'review' then
      local review_err
      diff_lines, review_err, list_opts = review.reload(bufnr, repo_root, path, review_deps())
      if not diff_lines then
        notify(review_err or 'cannot reload review buffer', vim.log.levels.WARN)
        return
      end
    elseif not stored_spec then
      local abs_path = repo_root .. '/' .. path

      local old_ok, old_rel_path = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_old_filepath')
      local old_abs_path = old_ok and old_rel_path and (repo_root .. '/' .. old_rel_path)
        or abs_path
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
    debug_label = debug_label or ((label or '?') .. ':' .. (path or '?'))
  end

  replace_generated_diff_buffer_lines(bufnr, diff_lines, stored_spec)
  lists.set_for_unified_buffer(bufnr, diff_lines, {
    title = 'diff: ' .. (debug_label or name:gsub('^diffs://', '')),
    diff_spec = stored_spec,
    metadata_for_line = list_opts and list_opts.metadata_for_line,
    sections = list_opts and list_opts.sections,
    store_hunks = list_opts and list_opts.store_hunks,
  })
  M.setup_diff_buf(bufnr)

  dbg('reloaded diff buffer %d (%s)', bufnr, debug_label)

  runtime.attach(bufnr)
end

function M.setup()
  vim.api.nvim_create_user_command('Gdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, false)
  end, {
    nargs = '*',
    complete = complete_gdiff_command,
    desc = 'Show unified diff against a Fugitive object',
  })

  vim.api.nvim_create_user_command('Gvdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, true)
  end, {
    nargs = '*',
    complete = complete_gdiff_split_command,
    desc = 'Show unified diff against a Fugitive object in vertical split',
  })

  vim.api.nvim_create_user_command('Ghdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, false)
  end, {
    nargs = '*',
    complete = complete_gdiff_split_command,
    desc = 'Show unified diff against a Fugitive object in horizontal split',
  })

  vim.api.nvim_create_user_command('Greview', function(opts)
    M.greview_command(opts.args ~= '' and opts.args or nil)
  end, {
    nargs = '*',
    complete = complete_greview_command,
    desc = 'Review the repo against the default branch or a git review spec',
  })
end

M._test = {
  complete_gdiff = complete_gdiff_command,
  complete_gdiff_object = complete_gdiff_object,
  complete_gdiff_split = complete_gdiff_split_command,
  complete_greview = review.complete,
  complete_greview_command = complete_greview_command,
  gdiff_buffer_label = gdiff_buffer_label,
  normalize_greview = review.normalize,
  parse_greview_command = review.parse_command_args,
  parse_review_arg = review.parse_arg,
}

return M
