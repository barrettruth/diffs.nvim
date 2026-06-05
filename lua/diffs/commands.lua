local M = {}

local actions = require('diffs.actions')
local content = require('diffs.content')
local diffspec = require('diffs.spec')
local gdiff_parser = require('diffs.gdiff')
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
local greview_workspace_group =
  vim.api.nvim_create_augroup('diffs_greview_workspace', { clear = false })

---@class diffs.HunkKeymap
---@field mode string
---@field lhs string
---@field callback function

---@type table<integer, diffs.HunkKeymap[]>
local hunk_keymaps = {}
---@type table<integer, integer>
local hunk_keymap_autocmds = {}

---@class diffs.GreviewWorkspaceState
---@field diff_buf integer
---@field diff_win integer?
---@field target_buf integer?
---@field target_win integer?
---@field target_scratch boolean
---@field review diffs.GreviewSpec
---@field display string
---@field repo_root string
---@field review_lines string[]
---@field list_opts table?
---@field selected_key string?
---@field selected_file string?
---@field selected_diff_spec diffs.DiffSpec?
---@field selected_hunk_index integer?
---@field autocmds integer[]

---@type table<integer, diffs.GreviewWorkspaceState>
local greview_workspaces = {}

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

  if source.kind == 'review_file' then
    local diff_lines, read_err = render.file(source.spec, source.repo_root, {
      empty_on_missing = true,
    })
    if not diff_lines then
      return nil, nil, read_err, nil
    end
    return diff_lines, source.spec, 'review:' .. (source.selected_key or source.path), nil
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
---@param opts? diffs.ReviewDepsOpts
---@return integer?
function M.greview(spec, opts)
  return review.greview(spec, review_deps(opts))
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

---@param layout? "unified"|"stacked"|"split"
---@return diffs.RailStyle
local function rail_style_for_layout(layout)
  if layout == 'stacked' then
    return 'single'
  end
  return 'dual'
end

local function warn_legacy_command()
  notify(
    ':Gdiff, :Gvdiff, :Ghdiff, and :Greview are deprecated. '
      .. 'Use :Diff and :Diff review instead. These aliases will be removed in 0.4.0.',
    vim.log.levels.WARN
  )
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
local gdiff_objects = {
  ':',
  ':%',
  ':0:%',
  '@:%',
}

local command_names = {
  Diff = true,
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
---@return { has_layout: boolean, has_value: boolean }
local function args_context(args, from)
  local has_layout = false
  local has_value = false
  for i = from or 1, #args do
    local token = args[i]
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
---@return { has_layout: boolean, has_value: boolean }
local function completion_context(arglead, cmdline, cursorpos)
  return args_context(command_arg_tokens(arglead, cmdline, cursorpos))
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
---@param context { has_layout: boolean, has_value: boolean }
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

---@param arglead string
---@param cmdline? string
---@param cursorpos? integer
---@return string[]
local function complete_greview_command(arglead, cmdline, cursorpos)
  return complete_review_args(arglead, completion_context(arglead, cmdline, cursorpos))
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
  local matches = {}
  if #args == 0 and not arglead:match('^%+%+') and starts_with('review', arglead) then
    matches[#matches + 1] = 'review'
  end
  vim.list_extend(matches, complete_gdiff_command(arglead, cmdline, cursorpos))
  return matches
end

---@type fun(spec?: diffs.GreviewSpec, opts?: { selection?: diffs.GeneratedFileSelection, replace_win?: integer }): integer?
local open_greview_workspace

---@param args? string
---@param vertical? boolean
---@param opts? { warn_vertical_split?: boolean }
---@return integer?
function M.greview_command(args, vertical, opts)
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
    return open_greview_workspace(parsed.spec)
  end

  parsed.spec.vertical = vertical or false
  local bufnr = M.greview(parsed.spec, {
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
      return M.greview_command(
        remainder ~= '' and remainder or nil,
        vertical,
        { warn_vertical_split = vertical }
      )
    end
  end
  return M.gdiff(args, vertical, { warn_vertical_split = vertical })
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

---@class diffs.GreviewSplitOpts
---@field bufnr? integer
---@field lnum? integer
---@field item? table

---@class diffs.GreviewSplitContext
---@field review_buf integer
---@field replace_win integer
---@field selected diffs.GeneratedFileSelection
---@field repo_root string

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

  local review_win = first_window_for_buffer(review_buf)
  if not review_win then
    return nil,
      'selected Greview buffer is not visible; open the review buffer before splitting it',
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

---@param normalized diffs.NormalizedGreview
---@return diffs.GreviewSpec
local function stored_review_spec(normalized)
  return {
    base = normalized.base,
    target = normalized.target,
    mode = normalized.mode,
  }
end

---@param review_spec diffs.GreviewSpec
---@param repo_root string
---@param selected diffs.GeneratedFileSelection
---@return diffs.DiffSpec?, diffs.NormalizedGreview?, string?
local function selected_review_diff_spec(review_spec, repo_root, selected)
  return review.diff_spec_for_file(review_spec, repo_root, selected.file, selected)
end

---@param state diffs.GreviewWorkspaceState
local function clear_greview_workspace_autocmds(state)
  for _, id in ipairs(state.autocmds or {}) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
  state.autocmds = {}
end

---@param bufnr integer
local function close_greview_workspace(bufnr)
  local state = greview_workspaces[bufnr]
  if not state then
    pcall(vim.api.nvim_win_close, 0, true)
    return
  end

  clear_greview_workspace_autocmds(state)
  greview_workspaces[bufnr] = nil

  local focus_win
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if buf ~= state.diff_buf and buf ~= state.target_buf then
        focus_win = win
        break
      end
    end
  end

  for _, win in ipairs({ state.target_win, state.diff_win }) do
    if type(win) == 'number' and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  if
    state.target_scratch
    and type(state.target_buf) == 'number'
    and vim.api.nvim_buf_is_valid(state.target_buf)
  then
    pcall(vim.api.nvim_buf_delete, state.target_buf, { force = true })
  end
  if vim.api.nvim_buf_is_valid(state.diff_buf) then
    pcall(vim.api.nvim_buf_delete, state.diff_buf, { force = true })
  end

  if focus_win and vim.api.nvim_win_is_valid(focus_win) then
    vim.api.nvim_set_current_win(focus_win)
  elseif #vim.api.nvim_list_wins() > 0 then
    pcall(vim.cmd.enew)
  end
end

---@param state diffs.GreviewWorkspaceState
---@param wins table<integer, boolean>
---@return boolean
local function greview_workspace_visible_in_wins(state, wins)
  for _, win in ipairs({ state.diff_win, state.target_win }) do
    if type(win) == 'number' and wins[win] then
      return true
    end
  end

  for win in pairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if buf == state.diff_buf or buf == state.target_buf then
        return true
      end
    end
  end
  return false
end

---@param display string
local function close_existing_greview_workspace(display)
  local current_wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    current_wins[win] = true
  end

  local to_close = {}
  for bufnr, state in pairs(greview_workspaces) do
    if greview_workspace_visible_in_wins(state, current_wins) then
      to_close[#to_close + 1] = bufnr
    end
  end
  for _, bufnr in ipairs(to_close) do
    close_greview_workspace(bufnr)
  end

  local existing_buf = vim.fn.bufnr('diffs://review-split:' .. display)
  if existing_buf ~= -1 and vim.api.nvim_buf_is_valid(existing_buf) then
    pcall(vim.api.nvim_buf_delete, existing_buf, { force = true })
  end
end

---@param win integer
---@param lnum integer
local function set_window_lnum(win, lnum)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  vim.api.nvim_win_set_cursor(win, { math.max(1, math.min(lnum, line_count)), 0 })
end

---@param hunk diffs.GdiffHunk
---@return integer
local function hunk_right_lnum(hunk)
  local range = hunk.new_range
  return math.max(1, range and range.start or 1)
end

---@param state diffs.GreviewWorkspaceState
---@return diffs.GdiffHunk[]
local function greview_workspace_hunks(state)
  return generated.hunks(state.diff_buf)
end

---@param state diffs.GreviewWorkspaceState
---@param hunk_index integer?
---@return diffs.GdiffHunk?
local function greview_workspace_hunk(state, hunk_index)
  local hunks = greview_workspace_hunks(state)
  return hunks[hunk_index or 1]
end

---@param state diffs.GreviewWorkspaceState
---@param hunk diffs.GdiffHunk?
local function move_greview_workspace_to_hunk(state, hunk)
  if not hunk then
    return
  end

  local diff_win = type(state.diff_win) == 'number'
      and vim.api.nvim_win_is_valid(state.diff_win)
      and state.diff_win
    or first_window_for_buffer(state.diff_buf)
  if diff_win then
    set_window_lnum(diff_win, hunk.buffer_range.start)
  end
  if type(state.target_win) == 'number' and vim.api.nvim_win_is_valid(state.target_win) then
    set_window_lnum(state.target_win, hunk_right_lnum(hunk))
  end
  state.selected_hunk_index = hunk.index
end

---@param bufnr integer
---@param direction "next"|"prev"
local function greview_workspace_goto_hunk(bufnr, direction)
  local state = greview_workspaces[bufnr]
  if not state then
    return
  end

  local hunks = greview_workspace_hunks(state)
  if #hunks == 0 then
    return
  end

  local diff_win = type(state.diff_win) == 'number'
      and vim.api.nvim_win_is_valid(state.diff_win)
      and state.diff_win
    or first_window_for_buffer(state.diff_buf)
  local cursor_line = diff_win and vim.api.nvim_win_get_cursor(diff_win)[1] or 1
  local hunk
  if direction == 'next' then
    hunk = hunk_model.next_hunk(hunks, cursor_line) or hunks[1]
    if hunk == hunks[1] and hunk.buffer_range.start <= cursor_line then
      notify('wrapped to first hunk', vim.log.levels.INFO)
    end
  else
    hunk = hunk_model.prev_hunk(hunks, cursor_line) or hunks[#hunks]
    if hunk == hunks[#hunks] and hunk.buffer_range.start >= cursor_line then
      notify('wrapped to last hunk', vim.log.levels.INFO)
    end
  end

  move_greview_workspace_to_hunk(state, hunk)
end

---@param bufnr integer
local function set_greview_workspace_keymaps(bufnr)
  vim.keymap.set('n', 'q', function()
    close_greview_workspace(bufnr)
  end, { buffer = bufnr, desc = 'Close Greview split workspace' })
  vim.keymap.set('n', ']c', function()
    greview_workspace_goto_hunk(bufnr, 'next')
  end, { buffer = bufnr, desc = 'Next diff hunk' })
  vim.keymap.set('n', '[c', function()
    greview_workspace_goto_hunk(bufnr, 'prev')
  end, { buffer = bufnr, desc = 'Previous diff hunk' })
end

---@param state diffs.GreviewWorkspaceState
---@param selected diffs.GeneratedFileSelection
---@param diff_spec diffs.DiffSpec
---@return diffs.GeneratedBufferSource
local function review_file_source(state, selected, diff_spec)
  return generated.review_file_source({
    repo_root = state.repo_root,
    review = state.review,
    review_display = state.display,
    selected_key = selected.key,
    selected_file = selected.file,
    path = selected.file,
    spec = diff_spec,
  })
end

---@param bufnr integer
---@param state diffs.GreviewWorkspaceState
---@param selected diffs.GeneratedFileSelection
---@param diff_spec diffs.DiffSpec
---@param diff_lines string[]
local function replace_review_file_buffer(bufnr, state, selected, diff_spec, diff_lines)
  set_diff_spec_var(bufnr, diff_spec)
  generated.set_repo_root(bufnr, state.repo_root)
  generated.set_source(bufnr, review_file_source(state, selected, diff_spec))
  replace_generated_diff_buffer_lines(bufnr, diff_lines, diff_spec)
  lists.set_for_unified_buffer(bufnr, diff_lines, {
    title = 'review: ' .. (selected.key or selected.file),
    loclist_title = 'review hunks: ' .. (selected.key or selected.file),
    diff_spec = diff_spec,
    quickfix = false,
  })
  M.setup_diff_buf(bufnr)
  set_greview_workspace_keymaps(bufnr)
  runtime.attach(bufnr)
end

---@param repo_root string
---@param path string
---@return string
local function worktree_path(repo_root, path)
  return repo_root .. '/' .. path
end

---@param endpoint diffs.Endpoint
---@return string
local function endpoint_name(endpoint)
  endpoint = diffspec.endpoint(endpoint)
  if endpoint.kind == diffspec.endpoint_kind.tree then
    return endpoint.rev
  end
  return endpoint.kind
end

---@param lines diffs.ContentLines|string[]
---@return string[]
local function plain_lines(lines)
  local result = {}
  for i, line in ipairs(lines or {}) do
    result[i] = line
  end
  return result
end

---@param state diffs.GreviewWorkspaceState
---@return integer
local function ensure_target_window(state)
  if type(state.target_win) == 'number' and vim.api.nvim_win_is_valid(state.target_win) then
    return state.target_win
  end

  local diff_win = type(state.diff_win) == 'number'
      and vim.api.nvim_win_is_valid(state.diff_win)
      and state.diff_win
    or first_window_for_buffer(state.diff_buf)
  if diff_win then
    vim.api.nvim_set_current_win(diff_win)
  end
  vim.cmd('rightbelow vsplit')
  state.target_win = vim.api.nvim_get_current_win()
  return state.target_win
end

---@param state diffs.GreviewWorkspaceState
---@param diff_spec diffs.DiffSpec
---@param selected diffs.GeneratedFileSelection
---@return boolean
local function open_workspace_target(state, diff_spec, selected)
  local target_win = ensure_target_window(state)
  local previous_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(target_win)
  pcall(vim.api.nvim_set_option_value, 'diff', false, { win = target_win })

  local target = diffspec.endpoint(diff_spec.right)
  local path = worktree_path(state.repo_root, selected.file)
  local previous_target_buf = state.target_buf
  local previous_target_scratch = state.target_scratch

  if target.kind == diffspec.endpoint_kind.worktree and vim.fn.filereadable(path) == 1 then
    vim.cmd.edit(vim.fn.fnameescape(path))
    state.target_buf = vim.api.nvim_get_current_buf()
    state.target_scratch = false
    if
      previous_target_scratch
      and type(previous_target_buf) == 'number'
      and previous_target_buf ~= state.target_buf
      and vim.api.nvim_buf_is_valid(previous_target_buf)
    then
      pcall(vim.api.nvim_buf_delete, previous_target_buf, { force = true })
    end
  else
    local lines, err = render.read_endpoint(target, path, { empty_on_missing = true })
    if not lines then
      notify(err or 'cannot read review target', vim.log.levels.WARN)
      restore_window(previous_win)
      return false
    end
    local target_buf = previous_target_scratch and previous_target_buf or nil
    if type(target_buf) ~= 'number' or not vim.api.nvim_buf_is_valid(target_buf) then
      target_buf = vim.api.nvim_create_buf(false, true)
    end
    local target_name = 'diffs://review-target:' .. endpoint_name(target) .. ':' .. selected.file
    local existing = vim.fn.bufnr(target_name)
    if existing ~= -1 and existing ~= target_buf and vim.api.nvim_buf_is_valid(existing) then
      pcall(vim.api.nvim_buf_delete, existing, { force = true })
    end
    vim.api.nvim_set_option_value('modifiable', true, { buf = target_buf })
    vim.api.nvim_buf_set_lines(target_buf, 0, -1, false, plain_lines(lines))
    vim.api.nvim_buf_set_name(target_buf, target_name)
    vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = target_buf })
    vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = target_buf })
    vim.api.nvim_set_option_value('swapfile', false, { buf = target_buf })
    vim.api.nvim_set_option_value('modifiable', false, { buf = target_buf })
    local ft = filetype_for_path(state.repo_root, selected.file)
    if ft then
      vim.api.nvim_set_option_value('filetype', ft, { buf = target_buf })
    end
    vim.api.nvim_win_set_buf(target_win, target_buf)
    state.target_buf = target_buf
    state.target_scratch = true
  end

  restore_window(previous_win)
  return true
end

---@param review_spec diffs.GreviewSpec
---@param repo_root string
---@param selected diffs.GeneratedFileSelection
---@return diffs.DiffSpec?, string[]?, string?, integer?
local function render_review_file_selection(review_spec, repo_root, selected)
  local diff_spec, _, spec_err = selected_review_diff_spec(review_spec, repo_root, selected)
  if not diff_spec then
    return nil, nil, spec_err or 'cannot build Greview split diff spec', vim.log.levels.ERROR
  end

  local diff_lines, render_err = render.file(diff_spec, repo_root, { empty_on_missing = true })
  if not diff_lines then
    return nil, nil, render_err or 'cannot render Greview split file', vim.log.levels.ERROR
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
  }
end

---@param review_spec diffs.GreviewSpec
---@param repo_root string
---@param review_lines string[]
---@param list_opts table?
---@return diffs.GeneratedFileSelection?, diffs.DiffSpec?, string[]?, string?, integer?
local function first_renderable_review_file(review_spec, repo_root, review_lines, list_opts)
  local last_err
  local last_level
  for _, selected in
    ipairs(lists.generated_files(review_lines, review_generated_list_opts(list_opts)))
  do
    local diff_spec, diff_lines, err, level =
      render_review_file_selection(review_spec, repo_root, selected)
    if diff_spec and diff_lines then
      return selected, diff_spec, diff_lines, nil, nil
    end
    last_err = err
    last_level = level
  end

  return nil,
    nil,
    nil,
    last_err or 'no renderable Greview file selected',
    last_level or vim.log.levels.INFO
end

---@param item table?
---@return diffs.GeneratedFileSelection?
local function review_selection_from_item(item)
  if type(item) ~= 'table' or type(item.user_data) ~= 'table' then
    return nil
  end
  local data = item.user_data.diffs
  if type(data) ~= 'table' or type(data.file) ~= 'string' or data.file == '' then
    return nil
  end
  return {
    bufnr = item.bufnr,
    file = data.file,
    key = data.key or data.file,
    section = data.section,
    section_label = data.section_label,
    diff_spec = data.diff_spec,
    lnum = item.lnum,
    hunk_index = data.hunk,
  }
end

local attach_greview_workspace_autocmds
local refresh_greview_workspace_after_write

---@param state diffs.GreviewWorkspaceState
---@param selected diffs.GeneratedFileSelection
---@param opts? { restore_focus?: boolean, restore_win?: integer, refresh_index?: boolean }
---@return boolean
local function show_greview_workspace_selection(state, selected, opts)
  opts = opts or {}
  local restore_win = opts.restore_win or vim.api.nvim_get_current_win()
  local diff_spec, _, spec_err = selected_review_diff_spec(state.review, state.repo_root, selected)
  if not diff_spec then
    notify(spec_err or 'cannot build Greview split diff spec', vim.log.levels.ERROR)
    return false
  end

  local diff_lines, render_err =
    render.file(diff_spec, state.repo_root, { empty_on_missing = true })
  if not diff_lines then
    notify(render_err or 'cannot render Greview split file', vim.log.levels.ERROR)
    return false
  end

  replace_review_file_buffer(state.diff_buf, state, selected, diff_spec, diff_lines)
  if opts.refresh_index then
    lists.set_review_workspace_quickfix(state.diff_buf, state.review_lines, {
      title = 'review: ' .. state.display,
      loclist_title = 'review hunks: ' .. state.display,
      metadata_for_line = state.list_opts and state.list_opts.metadata_for_line,
      sections = state.list_opts and state.list_opts.sections,
      store_hunks = state.list_opts and state.list_opts.store_hunks,
    })
  end

  local hunk = greview_workspace_hunk(state, selected.hunk_index)
  if not open_workspace_target(state, diff_spec, selected) then
    return false
  end
  state.selected_key = selected.key or selected.file
  state.selected_file = selected.file
  state.selected_diff_spec = diff_spec
  state.selected_hunk_index = selected.hunk_index
  move_greview_workspace_to_hunk(state, hunk)
  attach_greview_workspace_autocmds(state)

  if opts.restore_focus then
    restore_window(restore_win)
  elseif type(state.diff_win) == 'number' and vim.api.nvim_win_is_valid(state.diff_win) then
    vim.api.nvim_set_current_win(state.diff_win)
  end
  return true
end

---@param state diffs.GreviewWorkspaceState
local function refresh_greview_workspace_index(state)
  local normalized, normalize_err = review.normalize(state.review, state.repo_root)
  if not normalized then
    notify(normalize_err or 'cannot normalize Greview split', vim.log.levels.WARN)
    return
  end
  local review_lines, render_err, list_opts = review.render(normalized, review_deps())
  if not review_lines then
    notify(render_err or 'cannot refresh Greview split', vim.log.levels.WARN)
    return
  end
  state.review_lines = review_lines
  state.list_opts = list_opts
  lists.set_review_workspace_quickfix(state.diff_buf, review_lines, {
    title = 'review: ' .. state.display,
    loclist_title = 'review hunks: ' .. state.display,
    metadata_for_line = list_opts and list_opts.metadata_for_line,
    sections = list_opts and list_opts.sections,
    store_hunks = list_opts and list_opts.store_hunks,
  })
end

---@param state diffs.GreviewWorkspaceState
attach_greview_workspace_autocmds = function(state)
  clear_greview_workspace_autocmds(state)
  state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
    group = greview_workspace_group,
    buffer = state.diff_buf,
    once = true,
    callback = function(args)
      local current = greview_workspaces[args.buf]
      if current then
        clear_greview_workspace_autocmds(current)
        greview_workspaces[args.buf] = nil
      end
    end,
  })
  if
    type(state.target_buf) == 'number'
    and vim.api.nvim_buf_is_valid(state.target_buf)
    and not state.target_scratch
  then
    local diff_buf = state.diff_buf
    state.autocmds[#state.autocmds + 1] = vim.api.nvim_create_autocmd('BufWritePost', {
      group = greview_workspace_group,
      buffer = state.target_buf,
      callback = function()
        refresh_greview_workspace_after_write(diff_buf)
      end,
    })
  end
end

refresh_greview_workspace_after_write = function(diff_buf)
  local state = greview_workspaces[diff_buf]
  if not state or not state.selected_file then
    return
  end
  refresh_greview_workspace_index(state)
  show_greview_workspace_selection(state, {
    bufnr = state.diff_buf,
    file = state.selected_file,
    key = state.selected_key,
    diff_spec = state.selected_diff_spec,
    hunk_index = state.selected_hunk_index,
  }, { restore_focus = true, refresh_index = false })
end

local function refresh_greview_jump_callback()
  lists.set_generated_jump_callback(function(item)
    local selected = review_selection_from_item(item)
    if not selected or type(selected.bufnr) ~= 'number' then
      return
    end
    local state = greview_workspaces[selected.bufnr]
    if not state then
      return
    end
    vim.schedule(function()
      show_greview_workspace_selection(state, selected, {
        restore_focus = true,
        restore_win = vim.api.nvim_get_current_win(),
      })
    end)
  end)
end

open_greview_workspace = function(spec, opts)
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
  local diff_spec
  local diff_lines
  if first then
    local err, level
    diff_spec, diff_lines, err, level =
      render_review_file_selection(review_spec, normalized.repo_root, first)
    if not diff_spec or not diff_lines then
      notify(err or 'cannot render Greview split file', level or vim.log.levels.ERROR)
      return nil
    end
  else
    local err, level
    first, diff_spec, diff_lines, err, level =
      first_renderable_review_file(review_spec, normalized.repo_root, review_lines, list_opts)
    if not first or not diff_spec or not diff_lines then
      notify(err or 'no Greview file selected', level or vim.log.levels.INFO)
      return nil
    end
  end
  if not first then
    notify('no Greview file selected', vim.log.levels.INFO)
    return nil
  end

  local restore_win = vim.api.nvim_get_current_win()
  close_existing_greview_workspace(normalized.display)
  local replace_win = opts.replace_win
  if type(replace_win) == 'number' then
    if not vim.api.nvim_win_is_valid(replace_win) then
      notify('Greview split replacement window is no longer valid', vim.log.levels.WARN)
      return nil
    end
    vim.api.nvim_set_current_win(replace_win)
  else
    restore_window(restore_win)
  end

  local diff_buf = create_generated_diff_buffer({
    name = 'diffs://review-split:' .. normalized.display,
    lines = diff_lines,
    repo_root = normalized.repo_root,
    diff_spec = diff_spec,
    source = generated.review_file_source({
      repo_root = normalized.repo_root,
      review = review_spec,
      review_display = normalized.display,
      selected_key = first.key,
      selected_file = first.file,
      path = first.file,
      spec = diff_spec,
    }),
  })

  local diff_win = vim.api.nvim_get_current_win()
  clear_generated_diff_window_bindings(diff_win)
  pcall(vim.api.nvim_set_option_value, 'diff', false, { win = diff_win })
  vim.api.nvim_win_set_buf(diff_win, diff_buf)
  local state = {
    diff_buf = diff_buf,
    diff_win = diff_win,
    review = review_spec,
    display = normalized.display,
    repo_root = normalized.repo_root,
    review_lines = review_lines,
    list_opts = list_opts,
    selected_key = first.key or first.file,
    selected_file = first.file,
    selected_diff_spec = diff_spec,
    selected_hunk_index = first.hunk_index,
    target_scratch = false,
    autocmds = {},
  }
  greview_workspaces[diff_buf] = state

  lists.set_review_workspace_quickfix(diff_buf, review_lines, {
    title = 'review: ' .. normalized.display,
    loclist_title = 'review hunks: ' .. normalized.display,
    metadata_for_line = list_opts and list_opts.metadata_for_line,
    sections = list_opts and list_opts.sections,
    store_hunks = list_opts and list_opts.store_hunks,
  })
  lists.set_for_unified_buffer(diff_buf, diff_lines, {
    title = 'review: ' .. (first.key or first.file),
    loclist_title = 'review hunks: ' .. (first.key or first.file),
    diff_spec = diff_spec,
    quickfix = false,
  })
  attach_generated_diff_buffer(diff_buf)
  set_greview_workspace_keymaps(diff_buf)
  refresh_greview_jump_callback()
  if not open_workspace_target(state, diff_spec, first) then
    close_greview_workspace(diff_buf)
    return nil
  end
  move_greview_workspace_to_hunk(state, greview_workspace_hunk(state, first.hunk_index))
  attach_greview_workspace_autocmds(state)

  if diff_win and vim.api.nvim_win_is_valid(diff_win) then
    vim.api.nvim_set_current_win(diff_win)
  end

  return diff_buf
end

---@param opts? diffs.GreviewSplitOpts
---@return integer?
function M.greview_split(opts)
  local restore_win = vim.api.nvim_get_current_win()
  local context, err, level = greview_split_context(opts)
  if not context then
    restore_window(restore_win)
    notify(err or 'cannot open Greview split', level or vim.log.levels.WARN)
    return nil
  end

  local source, source_err = get_source_var(context.review_buf)
  if source_err or not source or source.kind ~= 'review' then
    restore_window(restore_win)
    notify(
      source_err and ('invalid diffs_source metadata: ' .. tostring(source_err))
        or 'selected file is not from a Greview buffer',
      vim.log.levels.WARN
    )
    return nil
  end

  local review_spec = vim.deepcopy(source.review)
  review_spec.repo = context.repo_root
  return open_greview_workspace(review_spec, {
    selection = context.selected,
    replace_win = context.replace_win,
  })
end

---@param args? string
---@param vertical? boolean
---@param opts? { warn_vertical_split?: boolean }
function M.gdiff(args, vertical, opts)
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

  local parsed, parse_err = gdiff_parser.parse(args, {
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

  if parsed.novertical then
    vertical = false
  end

  local rail_style = rail_style_for_layout(parsed.layout)
  local diff_spec = parsed.spec
  local diff_label = gdiff_buffer_label(diff_spec)
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
      notify('split Gdiff does not support unmerged files yet', vim.log.levels.ERROR)
      return
    end
    M.gdiff_file(filepath, {
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
      notify(split_err or 'cannot open split Gdiff', vim.log.levels.ERROR)
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
  dbg('opened diff buffer %d for %s (%s)', diff_buf, diff_path, diffspec.label(diff_spec))
end

---@class diffs.GdiffFileOpts
---@field vertical? boolean
---@field staged? boolean
---@field untracked? boolean
---@field unmerged? boolean
---@field old_filepath? string
---@field hunk_position? { hunk_header: string, offset: integer }
---@field rail_style? diffs.RailStyle

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

  local repo_root = source and source.repo_root or generated.repo_root(bufnr)
  if not repo_root then
    notify('cannot reload diffs:// buffer without diffs_repo_root', vim.log.levels.WARN)
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

  if source and source.kind == 'review_file' then
    local state = greview_workspaces[bufnr]
    if state then
      local selected_file = source.selected_file or source.path
      if not selected_file then
        notify('cannot reload Greview split buffer without selected file', vim.log.levels.WARN)
        return
      end
      refresh_greview_workspace_index(state)
      show_greview_workspace_selection(state, {
        bufnr = bufnr,
        file = selected_file,
        key = source.selected_key or selected_file,
        diff_spec = state.selected_diff_spec or source.spec,
        hunk_index = state.selected_hunk_index,
      }, { restore_focus = true, refresh_index = false })
      dbg('reloaded Greview split buffer %d (%s)', bufnr, debug_label)
      return
    end

    replace_generated_diff_buffer_lines(bufnr, diff_lines, stored_spec)
    lists.set_for_unified_buffer(bufnr, diff_lines, {
      title = 'review: ' .. (source.selected_key or source.path),
      loclist_title = 'review hunks: ' .. (source.selected_key or source.path),
      diff_spec = stored_spec,
      quickfix = false,
    })
    M.setup_diff_buf(bufnr)
    set_greview_workspace_keymaps(bufnr)
    dbg('reloaded Greview split buffer %d (%s)', bufnr, debug_label)
    runtime.attach(bufnr)
    return
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
  vim.api.nvim_create_user_command('Diff', function(opts)
    M.diff_command(opts.args ~= '' and opts.args or nil, opts.smods.vertical)
  end, {
    nargs = '*',
    bar = true,
    complete = complete_diff_command,
    desc = 'Show a current-file diff, or a repository review with :Diff review',
  })

  vim.api.nvim_create_user_command('Gdiff', function(opts)
    warn_legacy_command()
    M.gdiff(opts.args ~= '' and opts.args or nil, false)
  end, {
    nargs = '*',
    bar = true,
    complete = complete_gdiff_command,
    desc = 'Deprecated alias for :Diff',
  })

  vim.api.nvim_create_user_command('Gvdiff', function(opts)
    warn_legacy_command()
    M.gdiff(opts.args ~= '' and opts.args or nil, true)
  end, {
    nargs = '*',
    bar = true,
    complete = complete_gdiff_split_command,
    desc = 'Deprecated alias for :vertical Diff',
  })

  vim.api.nvim_create_user_command('Ghdiff', function(opts)
    warn_legacy_command()
    M.gdiff(opts.args ~= '' and opts.args or nil, false)
  end, {
    nargs = '*',
    bar = true,
    complete = complete_gdiff_split_command,
    desc = 'Deprecated alias for :Diff',
  })

  vim.api.nvim_create_user_command('Greview', function(opts)
    warn_legacy_command()
    M.greview_command(opts.args ~= '' and opts.args or nil)
  end, {
    nargs = '*',
    bar = true,
    complete = complete_greview_command,
    desc = 'Deprecated alias for :Diff review',
  })
end

M._test = {
  complete_diff = complete_diff_command,
  complete_gdiff = complete_gdiff_command,
  complete_gdiff_object = complete_gdiff_object,
  complete_gdiff_split = complete_gdiff_split_command,
  complete_greview = review.complete,
  complete_greview_command = complete_greview_command,
  create_generated_diff_buffer = create_generated_diff_buffer,
  gdiff_buffer_label = gdiff_buffer_label,
  replace_generated_diff_buffer_lines = replace_generated_diff_buffer_lines,
  close_greview_workspace = close_greview_workspace,
  greview_workspace_state = function(bufnr)
    return greview_workspaces[bufnr]
  end,
  normalize_greview = review.normalize,
  parse_greview_command = review.parse_command_args,
  parse_review_arg = review.parse_arg,
}

return M
