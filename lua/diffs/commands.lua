local M = {}

local actions = require('diffs.actions')
local content = require('diffs.content')
local diff_parser = require('diffs.diffargs')
local diffopt = require('diffs.diffopt')
local diffspec = require('diffs.spec')
local difftastic = require('diffs.difftastic')
local generated = require('diffs.generated')
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
local review_split_group = vim.api.nvim_create_augroup('diffs_review_split', { clear = false })

--- Paint difftastic structural intra spans onto a generated unified buffer and
--- emit the formatting-only notice when difft saw no structural change.
---@param diff_buf integer
---@param diff_lines string[]
---@param diff_spec diffs.DiffSpec?
---@param lhs table<integer, table[]>
---@param rhs table<integer, table[]>
local function paint_difft_unified(diff_buf, diff_lines, diff_spec, lhs, rhs)
  difftastic.apply_unified(
    diff_buf,
    lhs,
    rhs,
    diff_lines,
    diff_spec,
    rails.width_for_buffer(diff_buf)
  )
  if not difftastic.has_changes(lhs, rhs) then
    notify('difftastic: no structural changes (formatting only)', vim.log.levels.INFO)
  end
end

--- Apply difftastic to a generated unified buffer built from two content
--- arrays. No-op when difftastic is disabled/unavailable or content is missing.
---@param diff_buf integer
---@param diff_lines string[]
---@param diff_spec diffs.DiffSpec?
---@param old_lines string[]?
---@param new_lines string[]?
---@param relpath string
local function apply_difft_unified(diff_buf, diff_lines, diff_spec, old_lines, new_lines, relpath)
  if not difftastic.available() or not old_lines or not new_lines then
    return
  end
  local lhs, rhs = difftastic.span_maps_for_content(old_lines, new_lines, relpath)
  if lhs and rhs then
    paint_difft_unified(diff_buf, diff_lines, diff_spec, lhs, rhs)
  end
end

---@class diffs.HunkKeymap
---@field mode string
---@field lhs string
---@field callback function

---@type table<integer, diffs.HunkKeymap[]>
local hunk_keymaps = {}
---@type table<integer, integer>
local hunk_keymap_autocmds = {}

---@class diffs.ReviewSplitState
---@field left_buf integer
---@field right_buf integer
---@field left_win integer
---@field right_win integer
---@field review diffs.ReviewSpec
---@field repo_root string
---@field display string
---@field review_lines string[]
---@field list_opts table?
---@field selected_file string
---@field selected_key string?
---@field selected_diff_spec diffs.DiffSpec
---@field autocmds integer[]

---@type table<integer, diffs.ReviewSplitState>
local review_split_states = {}

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
  local has_hunks, parsed_hunks = generated.raw_hunks(bufnr)
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
    end, 'Unstage diff hunk')
    set_hunk_keymap(bufnr, 'x', 'do', function()
      local range_start, range_finish = visual_range(bufnr)
      if actions.obtain_range(bufnr, range_start, range_finish) then
        M.read_buffer(bufnr)
      end
    end, 'Unstage selected diff lines')
  end
  if can_put then
    set_hunk_keymap(bufnr, 'n', 'dp', function()
      if actions.put_hunk(bufnr) then
        M.read_buffer(bufnr)
      end
    end, 'Stage diff hunk')
    set_hunk_keymap(bufnr, 'x', 'dp', function()
      local range_start, range_finish = visual_range(bufnr)
      if actions.put_range(bufnr, range_start, range_finish) then
        M.read_buffer(bufnr)
      end
    end, 'Stage selected diff lines')
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
local function diff_buffer_label(diff_spec)
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

  if
    left.kind == diffspec.endpoint_kind.stage and right.kind == diffspec.endpoint_kind.worktree
  then
    return 'stage' .. left.stage
  end

  return diffspec.label(diff_spec)
end

---@param bufnr integer
---@param diff_spec diffs.DiffSpec
local function set_diff_spec_var(bufnr, diff_spec)
  generated.set_spec(bufnr, diff_spec)
end

---@param bufnr integer
---@param diff_lines string[]
---@param diff_spec diffs.DiffSpec
local function set_diff_hunks_var(bufnr, diff_lines, diff_spec)
  generated.set_hunks_from_lines(bufnr, diff_lines, diff_spec)
end

---@param bufnr integer
---@param info diffs.RailInfo?
local function set_diff_rails_var(bufnr, info)
  if info then
    vim.api.nvim_buf_set_var(bufnr, 'diffs_rail_width', info.prefix_width)
    vim.api.nvim_buf_set_var(bufnr, 'diffs_rail_separator_width', info.separator_width)
    if info.style == 'single' or info.style == 'dual' then
      vim.api.nvim_buf_set_var(bufnr, 'diffs_rail_style', info.style)
    else
      pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_rail_style')
    end
  else
    pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_rail_width')
    pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_rail_separator_width')
    pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_rail_style')
  end
end

---@param bufnr integer
local function clear_diff_hunks_var(bufnr)
  generated.clear_hunks(bufnr)
end

---@param bufnr integer
---@return diffs.DiffSpec?, string?
local function get_diff_spec_var(bufnr)
  return generated.spec(bufnr)
end

---@param bufnr integer
---@return diffs.GeneratedBufferSource?, string?
local function get_source_var(bufnr)
  return generated.source(bufnr)
end

---@param bufnr integer
local function set_generated_diff_buffer_options(bufnr)
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
end

---@param bufnr integer
local function set_generated_diff_buffer_filetype(bufnr)
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
---@field rail_style? diffs.RailStyle

---@param opts diffs.GeneratedDiffBufferOpts
---@return integer
local function create_generated_diff_buffer(opts)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local display_lines, rail_info = rails.annotate(opts.lines, {
    rail_separator = runtime.get_view_config().rail_separator,
    rail_style = opts.rail_style,
  })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, display_lines)
  vim.api.nvim_buf_set_name(bufnr, opts.name)
  set_diff_rails_var(bufnr, rail_info)

  if opts.diff_spec then
    set_diff_spec_var(bufnr, opts.diff_spec)
    set_diff_hunks_var(bufnr, opts.lines, opts.diff_spec)
  end
  if opts.repo_root then
    generated.set_repo_root(bufnr, opts.repo_root)
  end
  if opts.source then
    generated.set_source(bufnr, opts.source)
  end
  for name, value in pairs(opts.vars or {}) do
    if value ~= nil then
      vim.api.nvim_buf_set_var(bufnr, name, value)
    end
  end

  set_generated_diff_buffer_options(bufnr)
  set_generated_diff_buffer_filetype(bufnr)

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
---@param opts? { rail_style?: diffs.RailStyle }
local function replace_generated_diff_buffer_lines(bufnr, diff_lines, diff_spec, opts)
  opts = opts or {}
  difftastic.clear_active(bufnr)
  local display_lines, rail_info = rails.annotate(diff_lines, {
    rail_separator = runtime.get_view_config().rail_separator,
    rail_style = opts.rail_style or rails.style_for_buffer(bufnr),
  })
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, display_lines)
  set_diff_rails_var(bufnr, rail_info)

  if diff_spec then
    set_diff_hunks_var(bufnr, diff_lines, diff_spec)
  else
    clear_diff_hunks_var(bufnr)
  end

  set_generated_diff_buffer_options(bufnr)
  set_generated_diff_buffer_filetype(bufnr)
  runtime.refresh(bufnr)
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

---@class diffs.ReviewDepsOpts
---@field rail_style? diffs.RailStyle

---@param opts? diffs.ReviewDepsOpts
---@return diffs.ReviewDeps
local function review_deps(opts)
  opts = opts or {}
  return {
    create_generated_diff_buffer = create_generated_diff_buffer,
    show_generated_diff_buffer = show_generated_diff_buffer,
    attach_generated_diff_buffer = attach_generated_diff_buffer,
    replace_combined_diffs = replace_combined_diffs,
    rail_style = opts.rail_style,
  }
end

---@param repo_root string
---@param section "staged"|"unstaged"
---@return string[]
local function render_section_source(repo_root, section)
  local cmd = {
    'git',
    '-C',
    repo_root,
    'diff',
    '--no-ext-diff',
    '--no-color',
    '--src-prefix=a/',
    '--dst-prefix=b/',
  }
  vim.list_extend(cmd, diffopt.git_flags())
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

  if source.kind == 'files' then
    local old_lines = git.get_working_content(source.left_path)
    if not old_lines then
      return nil, nil, source.left_name .. ': file not readable', nil
    end
    local new_lines = git.get_working_content(source.right_path)
    if not new_lines then
      return nil, nil, source.right_name .. ': file not readable', nil
    end
    return render.unified_lines(old_lines, new_lines, source.left_name, source.right_name),
      nil,
      'files:' .. source.left_name .. ' -> ' .. source.right_name,
      nil
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

---@param spec? diffs.ReviewSpec
---@param opts? diffs.ReviewDepsOpts
---@return integer?
function M.review(spec, opts)
  return review.open(spec, review_deps(opts))
end

---@param buf integer
---@param lnum integer
---@return string?
function M.review_file_at_line(buf, lnum)
  return review.file_at_line(buf, lnum)
end

local layout_options = {
  '++layout=unified',
  '++layout=stacked',
  '++layout=split',
}

local untracked_options = {
  '++nountracked',
}

---@param layout? "unified"|"stacked"|"split"
---@return diffs.RailStyle
local function rail_style_for_layout(layout)
  if layout == 'stacked' then
    return 'single'
  end
  return 'dual'
end

local function warn_vertical_split_ignored()
  notify(
    '++layout=split ignores the :vertical modifier; the split layout manages its own windows',
    vim.log.levels.WARN
  )
end

-- Always-available object literals offered in completion. Merge-stage objects
-- (`:1:%`/`:2:%`/`:3:%`) are valid only during a conflict, so they are accepted
-- by the parser but not advertised here.
local diff_objects = {
  ':',
  ':%',
  ':0:%',
  '@:%',
}

local command_names = {
  Diff = true,
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
local function complete_diff_object(arglead)
  local matches = prefix_matches(diff_objects, arglead)
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
---@return string[] # completed argument tokens before the cursor, excluding the command name
local function command_arg_tokens(arglead, cmdline, cursorpos)
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

  local args = {}
  for i = command_index + 1, #tokens do
    args[#args + 1] = tokens[i]
  end
  return args
end

---@param args string[]
---@param from? integer # first argument index to scan (defaults to 1)
---@return { has_layout: boolean, has_untracked: boolean, has_value: boolean }
local function args_context(args, from)
  local has_layout = false
  local has_untracked = false
  local has_value = false
  for i = from or 1, #args do
    local token = args[i]
    if token:match('^%+%+layout=') then
      has_layout = true
    elseif token == '++nountracked' then
      has_untracked = true
    elseif not token:match('^%+%+') then
      has_value = true
    end
  end
  return {
    has_layout = has_layout,
    has_untracked = has_untracked,
    has_value = has_value,
  }
end

---@param arglead string
---@param cmdline? string
---@param cursorpos? integer
---@return { has_layout: boolean, has_untracked: boolean, has_value: boolean }
local function completion_context(arglead, cmdline, cursorpos)
  return args_context(command_arg_tokens(arglead, cmdline, cursorpos))
end

---@param arglead string
---@param cmdline? string
---@param cursorpos? integer
---@return string[]
local function complete_diff_args(arglead, cmdline, cursorpos)
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
  vim.list_extend(matches, complete_diff_object(arglead))
  return matches
end

---@param arglead string
---@param context { has_layout: boolean, has_untracked: boolean, has_value: boolean }
---@return string[]
local function complete_review_args(arglead, context)
  if context.has_value then
    return {}
  end
  if arglead:match('^%+%+') then
    local matches = {}
    if not context.has_layout then
      vim.list_extend(matches, prefix_matches(layout_options, arglead))
    end
    if not context.has_untracked then
      vim.list_extend(matches, prefix_matches(untracked_options, arglead))
    end
    vim.list_extend(matches, review.complete(arglead))
    return matches
  end
  local matches = {}
  if arglead == '' and not context.has_layout then
    vim.list_extend(matches, layout_options)
  end
  if arglead == '' and not context.has_untracked then
    vim.list_extend(matches, untracked_options)
  end
  vim.list_extend(matches, review.complete(arglead))
  return matches
end

local files_layout_options = {
  '++layout=unified',
  '++layout=stacked',
}

---@param arglead string
---@return string[]
local function complete_files_args(arglead)
  if arglead:match('^%+%+') then
    return prefix_matches(files_layout_options, arglead)
  end
  return vim.fn.getcompletion(arglead, 'file')
end

---@param arglead string
---@param cmdline? string
---@param cursorpos? integer
---@return string[]
local function complete_diff_command(arglead, cmdline, cursorpos)
  local args = command_arg_tokens(arglead, cmdline, cursorpos)
  if args[1] == 'review' then
    return complete_review_args(arglead, args_context(args, 2))
  end
  if args[1] == 'files' then
    return complete_files_args(arglead)
  end
  local matches = {}
  if #args == 0 and not arglead:match('^%+%+') then
    if starts_with('review', arglead) then
      matches[#matches + 1] = 'review'
    end
    if starts_with('files', arglead) then
      matches[#matches + 1] = 'files'
    end
  end
  vim.list_extend(matches, complete_diff_args(arglead, cmdline, cursorpos))
  return matches
end

---@type fun(spec?: diffs.ReviewSpec, opts?: { selection?: diffs.GeneratedFileSelection, replace_win?: integer }): integer?
local open_review_split

---@param args? string
---@param vertical? boolean
---@param opts? { warn_vertical_split?: boolean }
---@return integer?
function M.review_command(args, vertical, opts)
  opts = opts or {}
  local parsed, err = review.parse_command_args(args)
  if not parsed then
    notify(err, vim.log.levels.ERROR)
    return nil
  end

  if parsed.layout == 'split' then
    if opts.warn_vertical_split then
      warn_vertical_split_ignored()
    end
    return open_review_split(parsed.spec)
  end

  parsed.spec.vertical = vertical or false
  local bufnr = M.review(parsed.spec, {
    rail_style = rail_style_for_layout(parsed.layout),
  })
  return bufnr
end

--- Primary `:Diff` command handler. Routes `:Diff review ...` to the review
--- surface and everything else to the current-file diff, threading the
--- `:vertical` modifier through to generated layouts.
---@param args? string
---@param vertical? boolean
---@return integer?
function M.diff_command(args, vertical)
  vertical = vertical or false
  if args then
    local sub, remainder = args:match('^%s*(%S+)%s*(.*)$')
    if sub == 'review' then
      return M.review_command(
        remainder ~= '' and remainder or nil,
        vertical,
        { warn_vertical_split = vertical }
      )
    end
    if sub == 'files' then
      return M.diff_files_command(remainder ~= '' and remainder or nil, vertical)
    end
  end
  return M.diff(args, vertical, { warn_vertical_split = vertical })
end

---@param args? string
---@param vertical? boolean
---@return integer?
function M.diff_files_command(args, vertical)
  local parsed, err = diff_parser.parse_files(args)
  if not parsed then
    notify(err, vim.log.levels.ERROR)
    return nil
  end

  local layout = parsed.layout
  if layout == 'split' then
    notify(
      'split layout is not supported for :Diff files; use nvim -d or :diffsplit for side-by-side',
      vim.log.levels.ERROR
    )
    return nil
  end

  return M.diff_files(parsed.left, parsed.right, {
    layout = layout,
    vertical = vertical,
  })
end

---@class diffs.DiffFilesViewOpts
---@field layout "unified"|"stacked"|"split"
---@field vertical? boolean

---@param left string
---@param right string?
---@param opts? diffs.DiffFilesViewOpts
---@return integer?
function M.diff_files(left, right, opts)
  opts = opts or {}

  local right_input = right
  if not right_input then
    local current = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    if current == '' then
      notify('cannot diff unnamed buffer', vim.log.levels.ERROR)
      return nil
    end
    right_input = current
  end

  local left_abs = vim.fn.fnamemodify(vim.fn.expand(left), ':p')
  local right_abs = vim.fn.fnamemodify(vim.fn.expand(right_input), ':p')
  local left_name = vim.fn.fnamemodify(left_abs, ':~:.')
  if left_name == '' then
    left_name = left_abs
  end
  local right_name = vim.fn.fnamemodify(right_abs, ':~:.')
  if right_name == '' then
    right_name = right_abs
  end

  for _, side in ipairs({
    { abs = left_abs, name = left_name },
    { abs = right_abs, name = right_name },
  }) do
    if vim.fn.isdirectory(side.abs) == 1 then
      notify(side.name .. ' is a directory; :Diff files compares two files', vim.log.levels.ERROR)
      return nil
    end
    if vim.fn.filereadable(side.abs) ~= 1 then
      notify(side.name .. ': file not readable', vim.log.levels.ERROR)
      return nil
    end
  end

  local old_lines = git.get_working_content(left_abs) or {}
  local new_lines = git.get_working_content(right_abs) or {}
  if render.has_binary_lines(old_lines) or render.has_binary_lines(new_lines) then
    notify('diff does not support binary files', vim.log.levels.ERROR)
    return nil
  end

  local diff_lines = render.unified_lines(old_lines, new_lines, left_name, right_name)
  if #diff_lines == 0 then
    notify('no changes between ' .. left_name .. ' and ' .. right_name, vim.log.levels.INFO)
    return nil
  end

  local diff_buf = create_generated_diff_buffer({
    name = 'diffs://files:' .. left_name .. ' -> ' .. right_name,
    lines = diff_lines,
    source = generated.files_source(left_abs, right_abs, left_name, right_name),
    rail_style = rail_style_for_layout(opts.layout),
  })
  show_generated_diff_buffer(diff_buf, opts.vertical)
  lists.set_for_unified_buffer(diff_buf, diff_lines, {
    title = 'diff: files ' .. left_name .. ' -> ' .. right_name,
  })
  attach_generated_diff_buffer(diff_buf)

  if difftastic.available() then
    local lhs, rhs = difftastic.span_maps_for_paths(left_abs, right_abs)
    if lhs and rhs then
      paint_difft_unified(diff_buf, diff_lines, nil, lhs, rhs)
    end
  end

  dbg('opened files diff buffer %d (%s -> %s)', diff_buf, left_name, right_name)
  return diff_buf
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

---@class diffs.ReviewSplitOpts
---@field bufnr? integer
---@field lnum? integer
---@field item? table

---@class diffs.ReviewSplitContext
---@field review_buf integer
---@field replace_win integer
---@field selected diffs.GeneratedFileSelection
---@field repo_root string

---@param opts? diffs.ReviewSplitOpts
---@return diffs.ReviewSplitContext?, string?, integer?, integer?
local function review_split_context(opts)
  opts = opts or {}

  ---@type diffs.GeneratedFileSelectionOpts
  local selection_opts = {
    bufnr = opts.bufnr,
    lnum = opts.lnum,
    item = opts.item,
  }
  local selected, select_err = lists.selected_generated_file(selection_opts)
  if not selected then
    return nil, select_err or 'no review file selected', vim.log.levels.WARN, nil
  end

  local review_buf = selected.bufnr
  if not vim.api.nvim_buf_is_valid(review_buf) then
    return nil, 'selected review buffer is no longer valid', vim.log.levels.WARN, review_buf
  end

  local source, source_err = get_source_var(review_buf)
  if source_err then
    return nil,
      'invalid diffs_source metadata: ' .. tostring(source_err),
      vim.log.levels.WARN,
      review_buf
  end
  if not source or source.kind ~= 'review' then
    return nil, 'selected file is not from a review buffer', vim.log.levels.WARN, nil
  end

  local review_win = first_window_for_buffer(review_buf)
  if not review_win then
    return nil,
      'selected review buffer is not visible; open the review buffer before splitting it',
      vim.log.levels.WARN,
      review_buf
  end

  return {
    review_buf = review_buf,
    replace_win = review_win,
    selected = selected,
    repo_root = source.repo_root,
  },
    nil,
    nil,
    review_buf
end

---@param normalized diffs.NormalizedReview
---@return diffs.ReviewSpec
local function stored_review_spec(normalized)
  return {
    base = normalized.base,
    target = normalized.target,
    mode = normalized.mode,
    untracked = normalized.untracked,
  }
end

---@param review_spec diffs.ReviewSpec
---@param repo_root string
---@param selected diffs.GeneratedFileSelection
---@return diffs.DiffSpec?, diffs.NormalizedReview?, string?
local function selected_review_diff_spec(review_spec, repo_root, selected)
  return review.diff_spec_for_file(review_spec, repo_root, selected.file, selected)
end

---@param review_spec diffs.ReviewSpec
---@param repo_root string
---@param selected diffs.GeneratedFileSelection
---@return diffs.DiffSpec?, string[]?, string?, integer?
local function render_review_file_selection(review_spec, repo_root, selected)
  local diff_spec, _, spec_err = selected_review_diff_spec(review_spec, repo_root, selected)
  if not diff_spec then
    return nil, nil, spec_err or 'cannot build review split diff spec', vim.log.levels.ERROR
  end

  local diff_lines, render_err = render.file(diff_spec, repo_root, { empty_on_missing = true })
  if not diff_lines then
    return nil, nil, render_err or 'cannot render review split file', vim.log.levels.ERROR
  end
  if #diff_lines == 0 then
    return nil, nil, 'no changes for ' .. diffspec.label(diff_spec), vim.log.levels.INFO
  end
  return diff_spec, diff_lines, nil, nil
end

---@param list_opts table?
---@return diffs.GeneratedListOptions
local function review_generated_list_opts(list_opts)
  return {
    metadata_for_line = list_opts and list_opts.metadata_for_line,
    sections = list_opts and list_opts.sections,
    store_hunks = list_opts and list_opts.store_hunks,
    is_skipped = list_opts and list_opts.is_skipped,
  }
end

---@param review_spec diffs.ReviewSpec
---@param repo_root string
---@param review_lines string[]
---@param list_opts table?
---@return diffs.GeneratedFileSelection?, diffs.DiffSpec?, string[]?, string?, integer?, diffs.GeneratedFileSelection[]
local function first_renderable_review_file(review_spec, repo_root, review_lines, list_opts)
  local last_err
  local last_level
  local skipped = {}
  for _, selected in
    ipairs(lists.generated_files(review_lines, review_generated_list_opts(list_opts)))
  do
    if selected.skipped then
      skipped[#skipped + 1] = selected
    else
      local diff_spec, diff_lines, err, level =
        render_review_file_selection(review_spec, repo_root, selected)
      if diff_spec and diff_lines then
        return selected, diff_spec, diff_lines, nil, nil, skipped
      end
      skipped[#skipped + 1] = selected
      last_err = err
      last_level = level
    end
  end

  return nil,
    nil,
    nil,
    last_err or 'no renderable review file selected',
    last_level or vim.log.levels.INFO,
    skipped
end

---@param state diffs.ReviewSplitState
local function clear_review_split_autocmds(state)
  for _, id in ipairs(state.autocmds or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state.autocmds = {}
end

---@param state diffs.ReviewSplitState
local function forget_review_split(state)
  clear_review_split_autocmds(state)
  review_split_states[state.left_buf] = nil
  review_split_states[state.right_buf] = nil
end

---@param state diffs.ReviewSplitState
local function setup_review_split_panes(state)
  for _, buf in ipairs({ state.left_buf, state.right_buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].diffs_review = { display = state.display, layout = 'split' }
      if not get_buffer_keymap(buf, 'n', ']f') then
        vim.keymap.set('n', ']f', '<Plug>(diffs-review-next-file)', { buffer = buf, remap = true })
      end
      if not get_buffer_keymap(buf, 'n', '[f') then
        vim.keymap.set('n', '[f', '<Plug>(diffs-review-prev-file)', { buffer = buf, remap = true })
      end
      if not get_buffer_keymap(buf, 'n', 'gO') then
        vim.keymap.set(
          'n',
          'gO',
          '<Plug>(diffs-review-select-file)',
          { buffer = buf, remap = true }
        )
      end
    end
  end
end

---@param state diffs.ReviewSplitState
local function attach_review_split_autocmds(state)
  clear_review_split_autocmds(state)
  setup_review_split_panes(state)
  for _, buf in ipairs({ state.left_buf, state.right_buf }) do
    state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
      group = review_split_group,
      buffer = buf,
      once = true,
      callback = function()
        local current = review_split_states[buf]
        if current then
          forget_review_split(current)
        end
      end,
    })
  end
end

---@param state diffs.ReviewSplitState
---@param selected diffs.GeneratedFileSelection
---@param opts? { quiet?: boolean }
---@return boolean, boolean
local function switch_review_split_file(state, selected, opts)
  opts = opts or {}
  local diff_spec, diff_lines, err, level =
    render_review_file_selection(state.review, state.repo_root, selected)
  if not diff_spec or not diff_lines then
    if not opts.quiet then
      notify(err or 'cannot render review split file', level or vim.log.levels.WARN)
    end
    return false, true
  end

  local left_win = first_window_for_buffer(state.left_buf)
  local right_win = first_window_for_buffer(state.right_buf)
  if not left_win or not right_win then
    return false, false
  end

  local opened, split_err = split.open({
    spec = diff_spec,
    repo_root = state.repo_root,
    filetype = filetype_for_path(state.repo_root, selected.file),
    diff_lines = diff_lines,
    quickfix = false,
    change_bar = runtime.get_view_config().change_bar,
    title = 'review: ' .. state.display,
    hunk_index = selected.hunk_index or 1,
    reuse_wins = { left = left_win, right = right_win },
  })
  if not opened then
    notify(split_err or 'cannot open review split', vim.log.levels.ERROR)
    return false, false
  end

  forget_review_split(state)
  state.left_buf = opened.left_buf
  state.right_buf = opened.right_buf
  state.left_win = opened.left_win
  state.right_win = opened.right_win
  state.selected_file = selected.file
  state.selected_key = selected.key or selected.file
  state.selected_diff_spec = diff_spec
  review_split_states[state.left_buf] = state
  review_split_states[state.right_buf] = state
  attach_review_split_autocmds(state)
  return true, false
end

---@param state diffs.ReviewSplitState
---@return diffs.GeneratedFileSelection[]
local function review_split_files(state)
  return lists.generated_files(state.review_lines, review_generated_list_opts(state.list_opts))
end

---@param files diffs.GeneratedFileSelection[]
---@param state diffs.ReviewSplitState
---@return integer
local function review_index_of_current(files, state)
  for i, selection in ipairs(files) do
    if selection.key == state.selected_key or selection.file == state.selected_file then
      return i
    end
  end
  return 1
end

---@param selection diffs.GeneratedFileSelection
---@param index integer
---@param count integer
local function announce_review_file(selection, index, count)
  local label = selection.section_label
  local entry = (type(label) == 'string' and label ~= '')
      and ('[%s] %s'):format(label, selection.file)
    or selection.file
  notify(('(%d of %d): %s'):format(index, count, entry), vim.log.levels.INFO)
end

---@param skipped diffs.GeneratedFileSelection[]
local function notify_skipped_review_files(skipped)
  if #skipped == 0 then
    return
  end
  local paths = {}
  for _, selection in ipairs(skipped) do
    paths[#paths + 1] = selection.file
  end
  notify(
    ('review skipped %d file(s): %s'):format(#skipped, table.concat(paths, ', ')),
    vim.log.levels.INFO
  )
end

---@param state diffs.ReviewSplitState
---@param selection diffs.GeneratedFileSelection
---@param index integer
---@param count integer
---@return boolean
local function goto_selection(state, selection, index, count)
  if switch_review_split_file(state, selection) then
    announce_review_file(selection, index, count)
    return true
  end
  return false
end

---@param state diffs.ReviewSplitState
---@param delta integer
local function step_review_split_file(state, delta)
  local files = review_split_files(state)
  local count = #files
  if count < 2 then
    return
  end
  local current = review_index_of_current(files, state)
  local skipped = {}
  for offset = 1, count - 1 do
    local target = ((current - 1 + delta * offset) % count) + 1
    local selected = files[target]
    if selected.skipped then
      skipped[#skipped + 1] = selected
    else
      local switched, unsupported = switch_review_split_file(state, selected, { quiet = true })
      if switched then
        notify_skipped_review_files(skipped)
        announce_review_file(selected, target, count)
        return
      end
      if not unsupported then
        notify_skipped_review_files(skipped)
        return
      end
      skipped[#skipped + 1] = selected
    end
  end
  notify_skipped_review_files(skipped)
end

---@param delta integer
local function step_current_review_split(delta)
  local state = review_split_states[vim.api.nvim_get_current_buf()]
  if state then
    step_review_split_file(state, delta)
  end
end

function M.review_next_file()
  step_current_review_split(1)
end

function M.review_prev_file()
  step_current_review_split(-1)
end

---@class diffs.ReviewFile
---@field path string
---@field key string
---@field section? string
---@field section_label? string
---@field added integer
---@field removed integer
---@field skipped boolean

---@param selection diffs.GeneratedFileSelection
---@return diffs.ReviewFile
local function project_review_file(selection)
  return {
    path = selection.file,
    key = selection.key or selection.file,
    section = selection.section,
    section_label = selection.section_label,
    added = selection.added or 0,
    removed = selection.removed or 0,
    skipped = selection.skipped == true,
  }
end

---@param bufnr integer?
---@return diffs.ReviewSplitState?
local function resolve_review_split(bufnr)
  return review_split_states[bufnr or vim.api.nvim_get_current_buf()]
end

---@param bufnr integer? Defaults to the current buffer.
---@return diffs.ReviewFile[]? files Nil when the buffer is not a review split.
function M.review_files(bufnr)
  local state = resolve_review_split(bufnr)
  if not state then
    return nil
  end
  local files = {}
  for _, selection in ipairs(review_split_files(state)) do
    files[#files + 1] = project_review_file(selection)
  end
  return files
end

---@param bufnr integer? Defaults to the current buffer.
---@return { index: integer, count: integer, file: diffs.ReviewFile }?
function M.review_current(bufnr)
  local state = resolve_review_split(bufnr)
  if not state then
    return nil
  end
  local files = review_split_files(state)
  if #files == 0 then
    return nil
  end
  local index = review_index_of_current(files, state)
  return { index = index, count = #files, file = project_review_file(files[index]) }
end

---@param target string A review file key (preferred) or path.
---@param bufnr integer? Defaults to the current buffer.
---@return boolean switched
function M.review_goto(target, bufnr)
  local state = resolve_review_split(bufnr)
  if not state then
    return false
  end
  local files = review_split_files(state)
  for i, selection in ipairs(files) do
    if selection.key == target or selection.file == target then
      if selection.key == state.selected_key or selection.file == state.selected_file then
        return true
      end
      if selection.skipped then
        notify_skipped_review_files({ selection })
        return false
      end
      return goto_selection(state, selection, i, #files)
    end
  end
  return false
end

---@param file diffs.ReviewFile
---@return string
local function review_file_label(file)
  local path = file.skipped and (file.path .. ' (skipped)') or file.path
  if file.section_label and file.section_label ~= '' then
    return ('[%s] %s'):format(file.section_label, path)
  end
  return path
end

---@param files diffs.ReviewFile[]
---@return fun(file: diffs.ReviewFile): string
local function review_file_formatter(files)
  local labels = {}
  local max_label, max_add, max_del = 0, 0, 0
  for _, file in ipairs(files) do
    local label = review_file_label(file)
    labels[file.key] = label
    max_label = math.max(max_label, #label)
    if file.added > 0 then
      max_add = math.max(max_add, #tostring(file.added) + 1)
    end
    if file.removed > 0 then
      max_del = math.max(max_del, #tostring(file.removed) + 1)
    end
  end
  return function(file)
    local label = labels[file.key] or review_file_label(file)
    local parts = { label .. string.rep(' ', max_label - #label) }
    if max_add > 0 then
      parts[#parts + 1] = file.added > 0 and string.format('%' .. max_add .. 's', '+' .. file.added)
        or string.rep(' ', max_add)
    end
    if max_del > 0 then
      parts[#parts + 1] = file.removed > 0
          and string.format('%' .. max_del .. 's', '-' .. file.removed)
        or string.rep(' ', max_del)
    end
    return (table.concat(parts, ' '):gsub('%s+$', ''))
  end
end

---@param bufnr integer? Defaults to the current buffer.
function M.select_review_file(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local files = M.review_files(bufnr)
  if not files or #files == 0 then
    return
  end
  vim.ui.select(files, {
    prompt = 'Review file:',
    format_item = review_file_formatter(files),
  }, function(choice)
    if choice then
      M.review_goto(choice.key, bufnr)
    end
  end)
end

local function close_existing_review_splits()
  ---@type table<diffs.ReviewSplitState, boolean>
  local seen = {}
  for _, state in pairs(review_split_states) do
    if not seen[state] then
      seen[state] = true
      forget_review_split(state)
      if vim.api.nvim_buf_is_valid(state.left_buf) then
        split.close_pair(state.left_buf)
      elseif vim.api.nvim_buf_is_valid(state.right_buf) then
        split.close_pair(state.right_buf)
      end
    end
  end
end

---@param spec diffs.ReviewSpec?
---@param opts? { selection?: diffs.GeneratedFileSelection, replace_win?: integer }
---@return integer?
open_review_split = function(spec, opts)
  opts = opts or {}
  local normalized, normalize_err = review.normalize(spec)
  if not normalized then
    notify(normalize_err, vim.log.levels.ERROR)
    return nil
  end

  local review_lines, render_err, list_opts = review.render(normalized, review_deps())
  if not review_lines then
    notify(render_err, vim.log.levels.ERROR)
    return nil
  end
  if #review_lines == 0 then
    notify('no diff against ' .. normalized.display, vim.log.levels.INFO)
    return nil
  end

  local review_spec = stored_review_spec(normalized)
  local first = opts.selection
  local diff_spec, diff_lines
  local skipped = {}
  if first then
    if first.skipped then
      notify_skipped_review_files({ first })
      return nil
    end
    local err, level
    diff_spec, diff_lines, err, level =
      render_review_file_selection(review_spec, normalized.repo_root, first)
    if not diff_spec or not diff_lines then
      notify(err or 'cannot render review split file', level or vim.log.levels.ERROR)
      return nil
    end
  else
    local err, level
    first, diff_spec, diff_lines, err, level, skipped =
      first_renderable_review_file(review_spec, normalized.repo_root, review_lines, list_opts)
    if not first or not diff_spec or not diff_lines then
      notify_skipped_review_files(skipped)
      if #skipped == 0 then
        notify(err or 'no review file selected', level or vim.log.levels.INFO)
      end
      return nil
    end
  end

  local restore_win = vim.api.nvim_get_current_win()
  close_existing_review_splits()
  if type(opts.replace_win) == 'number' then
    if not vim.api.nvim_win_is_valid(opts.replace_win) then
      notify('review split replacement window is no longer valid', vim.log.levels.WARN)
      return nil
    end
    vim.api.nvim_set_current_win(opts.replace_win)
  else
    restore_window(restore_win)
  end

  local opened, split_err = split.open({
    spec = diff_spec,
    repo_root = normalized.repo_root,
    filetype = filetype_for_path(normalized.repo_root, first.file),
    diff_lines = diff_lines,
    quickfix = false,
    change_bar = runtime.get_view_config().change_bar,
    title = 'review: ' .. normalized.display,
    hunk_index = first.hunk_index or 1,
  })
  if not opened then
    notify(split_err or 'cannot open review split', vim.log.levels.ERROR)
    return nil
  end

  ---@type diffs.ReviewSplitState
  local state = {
    left_buf = opened.left_buf,
    right_buf = opened.right_buf,
    left_win = opened.left_win,
    right_win = opened.right_win,
    review = review_spec,
    repo_root = normalized.repo_root,
    display = normalized.display,
    review_lines = review_lines,
    list_opts = list_opts,
    selected_file = first.file,
    selected_key = first.key or first.file,
    selected_diff_spec = diff_spec,
    autocmds = {},
  }
  review_split_states[opened.left_buf] = state
  review_split_states[opened.right_buf] = state
  attach_review_split_autocmds(state)

  local files = lists.generated_files(review_lines, review_generated_list_opts(list_opts))
  local index = 1
  for i, selection in ipairs(files) do
    if selection.key == state.selected_key or selection.file == state.selected_file then
      index = i
      break
    end
  end
  notify_skipped_review_files(skipped)
  announce_review_file(first, index, #files)

  dbg('opened review split %d/%d (%s)', opened.left_buf, opened.right_buf, normalized.display)
  return opened.left_buf
end

---@param opts? diffs.ReviewSplitOpts
---@return integer?
function M.review_split(opts)
  local restore_win = vim.api.nvim_get_current_win()
  local context, err, level = review_split_context(opts)
  if not context then
    restore_window(restore_win)
    notify(err or 'cannot open review split', level or vim.log.levels.WARN)
    return nil
  end

  local source, source_err = get_source_var(context.review_buf)
  if source_err or not source or source.kind ~= 'review' then
    restore_window(restore_win)
    notify(
      source_err and ('invalid diffs_source metadata: ' .. tostring(source_err))
        or 'selected file is not from a review buffer',
      vim.log.levels.WARN
    )
    return nil
  end

  local review_spec = vim.deepcopy(source.review)
  review_spec.repo = context.repo_root
  return open_review_split(review_spec, {
    selection = context.selected,
    replace_win = context.replace_win,
  })
end

---@param args? string
---@param vertical? boolean
---@param opts? { warn_vertical_split?: boolean }
function M.diff(args, vertical, opts)
  opts = opts or {}
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

  local parsed, parse_err = diff_parser.parse(args, {
    path = rel_path,
    current = diffspec.worktree(),
  })
  if not parsed then
    notify(parse_err, vim.log.levels.ERROR)
    return
  end

  if parsed.layout == 'split' and opts.warn_vertical_split then
    warn_vertical_split_ignored()
  end

  local rail_style = rail_style_for_layout(parsed.layout)
  local diff_spec = parsed.spec
  local diff_label = diff_buffer_label(diff_spec)
  local diff_path = diff_spec.scope.path
  local repo_root = git.get_repo_root(filepath)
  if not repo_root then
    notify('not in a git repository', vim.log.levels.ERROR)
    return
  end

  local diff_filepath = repo_root .. '/' .. diff_path

  if diff_spec.left.kind == diffspec.endpoint_kind.stage and not git.is_unmerged(diff_filepath) then
    notify(diff_path .. ' is not in a merge conflict', vim.log.levels.ERROR)
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
      notify('split diff does not support unmerged files yet', vim.log.levels.ERROR)
      return
    end
    M.diff_file(filepath, {
      vertical = vertical,
      unmerged = true,
      rail_style = rail_style,
    })
    return
  end

  -- Only the current buffer's content stands in for the worktree side; an
  -- explicit-path object targets a different file that must be read from disk.
  local worktree_lines = diff_path == rel_path and content.from_buffer(bufnr) or nil
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
      change_bar = runtime.get_view_config().change_bar,
    })
    if not opened then
      notify(split_err or 'cannot open split diff', vim.log.levels.ERROR)
    end
    return
  end

  local diff_buf = create_generated_diff_buffer({
    name = 'diffs://' .. diff_label .. ':' .. diff_path,
    lines = diff_lines,
    repo_root = repo_root,
    diff_spec = diff_spec,
    source = generated.file_source(repo_root, diff_spec),
    rail_style = rail_style,
  })
  show_generated_diff_buffer(diff_buf, vertical)
  lists.set_for_unified_buffer(diff_buf, diff_lines, {
    title = 'diff: ' .. diffspec.label(diff_spec),
  })
  attach_generated_diff_buffer(diff_buf)

  if difftastic.available() then
    local abs = repo_root and (repo_root .. '/' .. diff_path) or diff_path
    local old_lines = render.read_endpoint(diff_spec.left, abs, { empty_on_missing = true })
    local new_lines = render.read_endpoint(diff_spec.right, abs, {
      worktree_lines = worktree_lines,
      empty_on_missing = true,
    })
    apply_difft_unified(diff_buf, diff_lines, diff_spec, old_lines, new_lines, diff_path)
  end

  dbg('opened diff buffer %d for %s (%s)', diff_buf, diff_path, diffspec.label(diff_spec))
end

---@class diffs.DiffFileOpts
---@field vertical? boolean
---@field staged? boolean
---@field untracked? boolean
---@field unmerged? boolean
---@field old_filepath? string
---@field hunk_position? { hunk_header: string, offset: integer }
---@field rail_style? diffs.RailStyle

---@param filepath string
---@param opts? diffs.DiffFileOpts
function M.diff_file(filepath, opts)
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
    source = generated.file_source(repo_root, diff_spec)
  elseif opts.unmerged then
    source = generated.unmerged_source(repo_root, rel_path, filepath)
  else
    local edge = opts.staged and 'staged' or 'unstaged'
    source = generated.file_pair_source(repo_root, edge, rel_path, old_rel_path)
  end

  local diff_buf = create_generated_diff_buffer({
    name = 'diffs://' .. diff_label .. ':' .. rel_path,
    lines = diff_lines,
    repo_root = repo_root,
    diff_spec = diff_spec,
    source = source,
    rail_style = opts.rail_style,
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

  if difftastic.available() and diff_label ~= 'unmerged' then
    ---@type diffs.ContentLines|string[]|nil
    local dold = old_lines
    ---@type diffs.ContentLines|string[]|nil
    local dnew = new_lines
    if (not dold or not dnew) and diff_spec then
      local abs = repo_root .. '/' .. rel_path
      dold = render.read_endpoint(diff_spec.left, abs, { empty_on_missing = true })
      dnew = render.read_endpoint(diff_spec.right, abs, { empty_on_missing = true })
    end
    apply_difft_unified(diff_buf, diff_lines, diff_spec, dold, dnew, rel_path)
  end

  if diff_label == 'unmerged' then
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_unmerged', true)
    vim.api.nvim_buf_set_var(diff_buf, 'diffs_working_path', filepath)
    local conflict_config = runtime.get_conflict_config()
    require('diffs.merge').setup_keymaps(diff_buf, conflict_config)
  end

  dbg('opened diff buffer %d for %s (%s)', diff_buf, rel_path, diff_label)
end

---@class diffs.DiffSectionOpts
---@field vertical? boolean
---@field staged? boolean

---@param repo_root string
---@param opts? diffs.DiffSectionOpts
function M.diff_section(repo_root, opts)
  opts = opts or {}

  local cmd = {
    'git',
    '-C',
    repo_root,
    'diff',
    '--no-ext-diff',
    '--no-color',
    '--src-prefix=a/',
    '--dst-prefix=b/',
  }
  vim.list_extend(cmd, diffopt.git_flags())
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
    source = generated.section_source(repo_root, diff_label),
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

  if source and source.kind == 'split_endpoint' then
    local ok, err = split.read_buffer(bufnr, source, {
      change_bar = runtime.get_view_config().change_bar,
    })
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
    local repo_root = generated.repo_root(bufnr)
    if not repo_root then
      notify('cannot reload diffs:// buffer without diffs_repo_root', vim.log.levels.WARN)
      return
    end
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

  local is_review = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_review_base')
  replace_generated_diff_buffer_lines(bufnr, diff_lines, stored_spec)
  lists.set_for_unified_buffer(bufnr, diff_lines, {
    title = 'diff: ' .. (debug_label or name:gsub('^diffs://', '')),
    diff_spec = stored_spec,
    metadata_for_line = list_opts and list_opts.metadata_for_line,
    sections = list_opts and list_opts.sections,
    store_hunks = list_opts and list_opts.store_hunks,
    quickfix = is_review or nil,
  })
  M.setup_diff_buf(bufnr)

  dbg('reloaded diff buffer %d (%s)', bufnr, debug_label)

  runtime.attach(bufnr)
end

--- Re-render every visible diffs:// buffer in place, preserving each window's
--- view. Used after a global change such as 'diffopt', so the new setting is
--- reflected consistently across all open diff surfaces.
function M.refresh_visible()
  ---@type { win: integer, view: table }[]
  local views = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf):match('^diffs://') then
      views[#views + 1] = { win = win, view = vim.api.nvim_win_call(win, vim.fn.winsaveview) }
    end
  end

  ---@type table<integer, boolean>
  local done = {}
  for _, entry in ipairs(views) do
    local buf = vim.api.nvim_win_is_valid(entry.win) and vim.api.nvim_win_get_buf(entry.win)
    if buf and not done[buf] and not difftastic.is_active(buf) then
      done[buf] = true
      local ok, peer = pcall(vim.api.nvim_buf_get_var, buf, 'diffs_split_peer')
      if ok and type(peer) == 'number' then
        done[peer] = true
      end
      M.read_buffer(buf)
    end
  end

  for _, entry in ipairs(views) do
    if vim.api.nvim_win_is_valid(entry.win) then
      vim.api.nvim_win_call(entry.win, function()
        vim.fn.winrestview(entry.view)
      end)
    end
  end
end

--- Re-render a single diffs:// buffer in place, preserving its window view.
---@param bufnr? integer
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_get_name(bufnr):match('^diffs://') then
    return
  end
  local win = first_window_for_buffer(bufnr)
  local view = win and vim.api.nvim_win_call(win, vim.fn.winsaveview) or nil
  M.read_buffer(bufnr)
  if win and view and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
  end
end

--- React to a runtime change of the global 'diffopt'. Generated diffs:// buffers
--- regenerate (their content honors the whitespace/algorithm flags), attached
--- repaint surfaces are invalidated so whitespace-only lines are re-classified,
--- and native &diff windows are refreshed so they pick up the new options
--- immediately. Deferred so buffer rewrites do not run inside the OptionSet
--- callback, then a redraw flushes the new highlighting.
function M.on_diffopt_changed()
  vim.schedule(function()
    M.refresh_visible()
    runtime.invalidate_attached()
    pcall(vim.cmd.diffupdate)
    vim.cmd.redraw({ bang = true })
  end)
end

function M.setup()
  vim.api.nvim_create_user_command('Diff', function(opts)
    M.diff_command(opts.args ~= '' and opts.args or nil, opts.smods.vertical)
  end, {
    nargs = '*',
    bar = true,
    complete = complete_diff_command,
    desc = 'Show a current-file diff, a repository review with :Diff review, or two files with :Diff files',
  })
end

M._test = {
  complete_diff = complete_diff_command,
  complete_diff_args = complete_diff_args,
  complete_diff_object = complete_diff_object,
  complete_review = review.complete,
  create_generated_diff_buffer = create_generated_diff_buffer,
  diff_buffer_label = diff_buffer_label,
  replace_generated_diff_buffer_lines = replace_generated_diff_buffer_lines,
  review_split_state = function(bufnr)
    return review_split_states[bufnr]
  end,
  normalize_review = review.normalize,
  parse_review_command = review.parse_command_args,
  parse_review_arg = review.parse_arg,
}

return M
