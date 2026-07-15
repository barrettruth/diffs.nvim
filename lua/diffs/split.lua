local M = {}

local diff = require('diffs.diff')
local diffspec = require('diffs.spec')
local difftastic = require('diffs.difftastic')
local generated = require('diffs.generated')
local hunk_model = require('diffs.hunks')
local lists = require('diffs.lists')
local log = require('diffs.log')
local render = require('diffs.render')

local notify = log.notify

local split_align = require('diffs.split_align')

---@type table<integer, boolean>
local closing_buffers = {}
---@type table<integer, integer>
local cleanup_autocmds = {}
---@type table<integer, integer>
local peer_buffers = {}
---@type table<integer, table<string, any>>
local pair_window_options = {}
---@type table<integer, integer>
local split_windows = {}
local win_closed_registered = false

---@class diffs.SplitPaneInfo
---@field rows diffs.SplitRow[]
---@field side "left"|"right"
---@field rail_width integer
---@field change_bar string
---@field anchors integer[]
---@field difft_intra? table<integer, {col_start: integer, col_end: integer}[]>

---@type table<integer, diffs.SplitPaneInfo>
local pane_info = {}
local split_line_ns = vim.api.nvim_create_namespace('diffs_split_line')
local split_intra_ns = vim.api.nvim_create_namespace('diffs_split_intra')
local default_change_bar = '▏'
local split_statuscolumn = "%!v:lua.require'diffs.split'.statuscolumn()"

---@class diffs.SplitReuseWins
---@field left integer
---@field right integer

---@class diffs.SplitOpenOpts
---@field spec diffs.DiffSpec
---@field repo_root string
---@field filetype? string
---@field worktree_lines? diffs.ContentLines|string[]
---@field diff_lines? string[]
---@field hunk_index? integer
---@field quickfix? boolean
---@field change_bar? string
---@field title? string
---@field reuse_wins? diffs.SplitReuseWins

---@class diffs.SplitEndpointSource
---@field version integer
---@field kind "split_endpoint"
---@field repo_root string
---@field spec diffs.DiffSpec
---@field side "left"|"right"
---@field path string
---@field filetype? string
---@field quickfix? boolean

---@param repo_root string
---@param path string
---@return string
local function abs_path(repo_root, path)
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

---@param diff_spec diffs.DiffSpec
---@param side "left"|"right"
---@return diffs.Endpoint
local function side_endpoint(diff_spec, side)
  diff_spec = diffspec.new(diff_spec)
  return side == 'left' and diff_spec.left or diff_spec.right
end

---@param lines string[]
---@return string[]
local function plain_lines(lines)
  local result = {}
  for i, line in ipairs(lines) do
    result[i] = line
  end
  return result
end

---@param source diffs.SplitEndpointSource
---@param opts? { worktree_lines?: diffs.ContentLines|string[] }
---@return string[]?, string?
local function endpoint_lines(source, opts)
  opts = opts or {}
  local spec = diffspec.new(source.spec)
  local lines, err = render.read_endpoint(
    side_endpoint(spec, source.side),
    abs_path(source.repo_root, source.path),
    {
      worktree_lines = opts.worktree_lines,
      empty_on_missing = true,
    }
  )
  if not lines then
    return nil, err or ('could not read ' .. source.side .. ' endpoint')
  end
  return plain_lines(lines), nil
end

---@param diff_lines string[]?
---@param spec diffs.DiffSpec
---@return diffs.DiffHunk[]
local function split_hunks_for(diff_lines, spec)
  if not diff_lines then
    return {}
  end
  return hunk_model.parse(diff_lines, spec)
end

---@param bufnr integer
---@param source diffs.SplitEndpointSource
---@param split_hunks? diffs.DiffHunk[]
local function set_source_vars(bufnr, source, split_hunks)
  generated.set_repo_root(bufnr, source.repo_root)
  generated.set_spec(bufnr, source.spec)
  generated.set_source(bufnr, source)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_split_side', source.side)
  if split_hunks then
    vim.api.nvim_buf_set_var(bufnr, 'diffs_split_hunks', split_hunks)
  else
    pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_split_hunks')
  end
end

---@class diffs.SplitSideConfig
---@field kind "delete"|"add"
---@field lnum "old_lnum"|"new_lnum"
---@field spans "del_spans"|"add_spans"
---@field line_hl string
---@field text_hl string
---@field bar_hl string
---@field nr_hl string

---@type table<"left"|"right", diffs.SplitSideConfig>
local side_config = {
  left = {
    kind = 'delete',
    lnum = 'old_lnum',
    spans = 'del_spans',
    line_hl = 'DiffsDelete',
    text_hl = 'DiffsDeleteText',
    bar_hl = 'DiffsDeleteBar',
    nr_hl = 'DiffsDeleteRailNr',
  },
  right = {
    kind = 'add',
    lnum = 'new_lnum',
    spans = 'add_spans',
    line_hl = 'DiffsAdd',
    text_hl = 'DiffsAddText',
    bar_hl = 'DiffsAddBar',
    nr_hl = 'DiffsAddRailNr',
  },
}

---@param source integer? diff-mapped source line number for this row
---@param width integer
---@param number boolean
---@return string
local function rail_number(source, width, number)
  if not number then
    return ''
  end
  if not source then
    return string.rep(' ', width)
  end
  return ('%' .. width .. 'd'):format(source)
end

---@param info diffs.SplitPaneInfo
---@param lnum integer
---@param number boolean
---@return string
local function rail_segment(info, lnum, number)
  local width = info.rail_width
  local row = info.rows[lnum]
  if not row or row.kind == 'filler' then
    local pad = number and width + 2 or 2
    return '%C%s%#DiffsRail#' .. string.rep(' ', pad)
  end
  local cfg = side_config[info.side]
  local numstr = rail_number(row[cfg.lnum], width, number)
  if row.kind == cfg.kind then
    return ('%%C%%s%%#%s#%s%%#%s#%s%%#%s# '):format(
      cfg.bar_hl,
      info.change_bar,
      cfg.nr_hl,
      numstr,
      cfg.line_hl
    )
  end
  return ('%%C%%s%%#DiffsRailNr# %s '):format(numstr)
end

---@return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  if not win or win == 0 then
    return ''
  end
  local ok, bufnr = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then
    return ''
  end
  local info = pane_info[bufnr]
  if not info then
    return ''
  end
  local number = vim.api.nvim_get_option_value('number', { win = win })
  local rendered_ok, rendered = pcall(rail_segment, info, vim.v.lnum, number)
  return rendered_ok and rendered or ''
end

---@param bufnr integer
---@param info diffs.SplitPaneInfo
local function set_split_line_bg(bufnr, info)
  vim.api.nvim_buf_clear_namespace(bufnr, split_line_ns, 0, -1)
  local priorities = require('diffs.runtime').get_highlight_opts().highlights.priorities
  local cfg = side_config[info.side]
  for lnum, row in ipairs(info.rows) do
    if row.kind == cfg.kind then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, split_line_ns, lnum - 1, 0, {
        end_row = lnum,
        end_col = 0,
        hl_group = cfg.line_hl,
        hl_eol = true,
        priority = priorities.line_bg,
      })
    end
  end
end

---@param bufnr integer
---@param info diffs.SplitPaneInfo
local function set_split_intra_difft(bufnr, info)
  local opts = require('diffs.runtime').get_highlight_opts()
  local intra_cfg = opts.highlights.intra
  if not intra_cfg or not intra_cfg.enabled then
    return
  end
  local cfg = side_config[info.side]
  local priority = opts.highlights.priorities.char_bg
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for row_index, spans in pairs(info.difft_intra) do
    if row_index >= 1 and row_index <= line_count then
      for _, span in ipairs(spans) do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, split_intra_ns, row_index - 1, span.col_start, {
          end_col = span.col_end,
          hl_group = cfg.text_hl,
          priority = priority,
        })
      end
    end
  end
end

---@param bufnr integer
---@param info diffs.SplitPaneInfo
---@param hunks diffs.DiffHunk[]
local function set_split_intra(bufnr, info, hunks)
  vim.api.nvim_buf_clear_namespace(bufnr, split_intra_ns, 0, -1)
  if info.difft_intra then
    return set_split_intra_difft(bufnr, info)
  end
  if not hunks or #hunks == 0 then
    return
  end

  local opts = require('diffs.runtime').get_highlight_opts()
  local intra_cfg = opts.highlights.intra
  if not intra_cfg or not intra_cfg.enabled then
    return
  end

  local cfg = side_config[info.side]
  local priority = opts.highlights.priorities.char_bg

  ---@type table<integer, integer>
  local lnum_to_row = {}
  for row_index, row in ipairs(info.rows) do
    local source_lnum = row[cfg.lnum]
    if source_lnum then
      lnum_to_row[source_lnum] = row_index
    end
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)

  for _, hunk in ipairs(hunks) do
    ---@type string[]
    local texts = {}
    ---@type diffs.DiffHunkLine[]
    local refs = {}
    for _, line in ipairs(hunk.lines or {}) do
      if line.kind ~= 'header' then
        texts[#texts + 1] = line.text
        refs[#refs + 1] = line
      end
    end

    if #texts > 0 and #texts <= intra_cfg.max_lines then
      local intra = diff.compute_intra_hunks(texts, intra_cfg.algorithm)
      local spans = intra and intra[cfg.spans] or {}
      for _, span in ipairs(spans) do
        local ref = refs[span.line]
        local source_lnum = ref and ref.kind == cfg.kind and ref[cfg.lnum]
        local buf_row = source_lnum and lnum_to_row[source_lnum]
        local col_start = span.col_start - 1
        local col_end = span.col_end - 1
        if
          buf_row
          and buf_row >= 1
          and buf_row <= line_count
          and col_start >= 0
          and col_end > col_start
        then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, split_intra_ns, buf_row - 1, col_start, {
            end_col = col_end,
            hl_group = cfg.text_hl,
            priority = priority,
          })
        end
      end
    end
  end
end

---@param bufnr integer
---@param filetype? string
local function set_buffer_options(bufnr, filetype)
  vim.api.nvim_set_option_value('buftype', 'nowrite', { buf = bufnr })
  vim.api.nvim_set_option_value('bufhidden', 'delete', { buf = bufnr })
  vim.api.nvim_set_option_value('swapfile', false, { buf = bufnr })
  vim.api.nvim_set_option_value('modifiable', false, { buf = bufnr })
  if filetype and filetype ~= '' then
    vim.api.nvim_set_option_value('filetype', filetype, { buf = bufnr })
  end
end

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
---@param lhs string
---@param desc string
local function clear_owned_keymap(bufnr, lhs, desc)
  local keymap = get_buffer_keymap(bufnr, 'n', lhs)
  if keymap and keymap.desc == desc then
    pcall(vim.keymap.del, 'n', lhs, { buffer = bufnr })
  end
end

---@param bufnr integer
local function clear_owned_split_keymaps(bufnr)
  clear_owned_keymap(bufnr, 'q', 'Close split diff')
  clear_owned_keymap(bufnr, '<CR>', 'Open source file')
  clear_owned_keymap(bufnr, ']c', 'Next diff hunk')
  clear_owned_keymap(bufnr, '[c', 'Previous diff hunk')
end

---@param bufnr integer
local function set_keymaps(bufnr)
  if not get_buffer_keymap(bufnr, 'n', 'q') then
    vim.keymap.set('n', 'q', function()
      M.close_pair(vim.api.nvim_get_current_buf())
    end, { buffer = bufnr, desc = 'Close split diff' })
  end
  if not get_buffer_keymap(bufnr, 'n', '<CR>') then
    vim.keymap.set('n', '<CR>', function()
      M.open_source(vim.api.nvim_get_current_buf())
    end, { buffer = bufnr, desc = 'Open source file' })
  end
  if not get_buffer_keymap(bufnr, 'n', ']c') then
    vim.keymap.set('n', ']c', function()
      M.goto_next(vim.api.nvim_get_current_buf())
    end, { buffer = bufnr, desc = 'Next diff hunk' })
  end
  if not get_buffer_keymap(bufnr, 'n', '[c') then
    vim.keymap.set('n', '[c', function()
      M.goto_prev(vim.api.nvim_get_current_buf())
    end, { buffer = bufnr, desc = 'Previous diff hunk' })
  end
end

---@param source diffs.SplitEndpointSource
---@return string
local function buffer_name(source)
  local spec = diffspec.new(source.spec)
  local endpoint = side_endpoint(spec, source.side)
  return 'diffs://split:' .. source.side .. ':' .. endpoint_name(endpoint) .. ':' .. source.path
end

---@param bufnr integer
---@param source diffs.SplitEndpointSource
---@param info diffs.SplitPaneInfo
---@param hunks diffs.DiffHunk[]
local function paint_pane(bufnr, source, info, hunks)
  pane_info[bufnr] = info
  set_source_vars(bufnr, source, hunks)
  if info.difft_intra then
    difftastic.mark_active(bufnr)
  end
  set_split_line_bg(bufnr, info)
  set_split_intra(bufnr, info, hunks)
end

---@param source diffs.SplitEndpointSource
---@param lines string[]
---@param info diffs.SplitPaneInfo
---@param hunks diffs.DiffHunk[]
---@return integer
local function create_buffer(source, lines, info, hunks)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(bufnr, buffer_name(source))
  paint_pane(bufnr, source, info, hunks)
  set_buffer_options(bufnr, source.filetype)
  set_keymaps(bufnr)
  return bufnr
end

---@param win integer
local function remember_pair_window_options(win)
  if pair_window_options[win] or not vim.api.nvim_win_is_valid(win) then
    return
  end

  pair_window_options[win] = {
    scrollbind = vim.api.nvim_get_option_value('scrollbind', { win = win }),
    cursorbind = vim.api.nvim_get_option_value('cursorbind', { win = win }),
    wrap = vim.api.nvim_get_option_value('wrap', { win = win }),
    foldmethod = vim.api.nvim_get_option_value('foldmethod', { win = win }),
    foldenable = vim.api.nvim_get_option_value('foldenable', { win = win }),
    statuscolumn = vim.api.nvim_get_option_value('statuscolumn', { win = win }),
    winhighlight = vim.api.nvim_get_option_value('winhighlight', { win = win }),
  }
end

---@param win integer
local function set_pair_window_options(win)
  remember_pair_window_options(win)
  vim.api.nvim_set_option_value('scrollbind', true, { win = win })
  vim.api.nvim_set_option_value('cursorbind', true, { win = win })
  vim.api.nvim_set_option_value('wrap', false, { win = win })
  vim.api.nvim_set_option_value('statuscolumn', split_statuscolumn, { win = win })
  vim.api.nvim_set_option_value('foldmethod', 'manual', { win = win })
  vim.api.nvim_set_option_value('foldenable', false, { win = win })
end

---@param win integer
local function clear_pair_window_options(win)
  local saved = pair_window_options[win]
  if saved then
    pair_window_options[win] = nil
    for name, value in pairs(saved) do
      pcall(vim.api.nvim_set_option_value, name, value, { win = win })
    end
    return
  end

  pcall(vim.api.nvim_set_option_value, 'scrollbind', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'cursorbind', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'foldenable', true, { win = win })
  pcall(vim.api.nvim_set_option_value, 'statuscolumn', '', { win = win })
end

---@param bufnr integer
---@return integer?
local function stored_split_peer(bufnr)
  local ok, peer = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_split_peer')
  if ok and type(peer) == 'number' then
    return peer
  end
  peer = peer_buffers[bufnr]
  if type(peer) == 'number' then
    return peer
  end
  return nil
end

---@param bufnr integer
---@return integer?
local function split_peer(bufnr)
  local peer = stored_split_peer(bufnr)
  if peer and vim.api.nvim_buf_is_valid(peer) then
    return peer
  end
  return nil
end

---@type fun(source: table): diffs.SplitEndpointSource
local normalize_source

---@param bufnr integer
---@return diffs.SplitEndpointSource?
local function buffer_source(bufnr)
  local ok, source = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_source')
  if ok and type(source) == 'table' and source.kind == 'split_endpoint' then
    return normalize_source(source)
  end
  return nil
end

---@param bufnr integer
local function ensure_pair_cleanup(bufnr)
  if cleanup_autocmds[bufnr] then
    return
  end

  cleanup_autocmds[bufnr] = vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      local peer = peer_buffers[bufnr] or split_peer(bufnr)
      cleanup_autocmds[bufnr] = nil
      peer_buffers[bufnr] = nil
      if closing_buffers[bufnr] or not peer or vim.v.exiting ~= vim.NIL then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(peer) then
          M.close_pair(peer)
        end
      end)
    end,
  })
end

local function register_win_closed()
  if win_closed_registered then
    return
  end
  win_closed_registered = true
  vim.api.nvim_create_autocmd('WinClosed', {
    callback = function(args)
      local win = tonumber(args.match)
      if not win then
        return
      end
      local bufnr = split_windows[win]
      split_windows[win] = nil
      if not bufnr or vim.v.exiting ~= vim.NIL then
        return
      end
      if closing_buffers[bufnr] or not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) and not closing_buffers[bufnr] then
          M.close_pair(bufnr)
        end
      end)
    end,
  })
end

---@param win integer
---@param bufnr integer
local function track_split_window(win, bufnr)
  register_win_closed()
  split_windows[win] = bufnr
end

---@param left_buf integer
---@param right_buf integer
local function set_peers(left_buf, right_buf)
  vim.api.nvim_buf_set_var(left_buf, 'diffs_split_peer', right_buf)
  vim.api.nvim_buf_set_var(right_buf, 'diffs_split_peer', left_buf)
  peer_buffers[left_buf] = right_buf
  peer_buffers[right_buf] = left_buf
  ensure_pair_cleanup(left_buf)
  ensure_pair_cleanup(right_buf)
end

---@param bufnr integer
---@param keep_closing? boolean
local function clear_pair_tracking(bufnr, keep_closing)
  if cleanup_autocmds[bufnr] then
    pcall(vim.api.nvim_del_autocmd, cleanup_autocmds[bufnr])
    cleanup_autocmds[bufnr] = nil
  end
  peer_buffers[bufnr] = nil
  pane_info[bufnr] = nil
  for win, win_buf in pairs(split_windows) do
    if win_buf == bufnr then
      split_windows[win] = nil
    end
  end
  if not keep_closing then
    closing_buffers[bufnr] = nil
  end
end

---@param bufnr integer
local function clear_split_state(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  clear_pair_tracking(bufnr)
  pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_split_peer')
  pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_split_hunks')
  pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_split_side')
  vim.api.nvim_buf_clear_namespace(bufnr, split_line_ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, split_intra_ns, 0, -1)
  clear_owned_split_keymaps(bufnr)
end

---@param bufnr integer
local function detach_split_endpoint(bufnr)
  local peer = stored_split_peer(bufnr)
  clear_split_state(bufnr)
  if peer and peer ~= bufnr and vim.api.nvim_buf_is_valid(peer) then
    clear_split_state(peer)
  end
end

---@param bufnr integer
---@return integer[]
local function windows_for_buffer(bufnr)
  local wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      wins[#wins + 1] = win
    end
  end
  return wins
end

---@param bufnr integer
---@return integer?
local function first_window_for_buffer(bufnr)
  return windows_for_buffer(bufnr)[1]
end

---@param bufnr integer
---@return integer?
local function current_or_first_window_for_buffer(bufnr)
  local current_win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current_win) and vim.api.nvim_win_get_buf(current_win) == bufnr then
    return current_win
  end
  return first_window_for_buffer(bufnr)
end

---@param bufnr integer
---@param lnum integer
---@return integer
local function clamp_lnum(bufnr, lnum)
  return math.max(1, math.min(lnum, vim.api.nvim_buf_line_count(bufnr)))
end

---@param anchors integer[]
---@return integer[]
local function sorted_anchors(anchors)
  local rows = {}
  for _, row in pairs(anchors or {}) do
    rows[#rows + 1] = row
  end
  table.sort(rows)
  return rows
end

---@param win integer
---@param lnum integer
local function set_window_lnum(win, lnum)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local bufnr = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_cursor(win, { clamp_lnum(bufnr, lnum), 0 })
end

---@param bufnr integer
---@param row integer
local function move_pair_to_row(bufnr, row)
  for _, win in ipairs(windows_for_buffer(bufnr)) do
    set_window_lnum(win, row)
  end
  local peer = split_peer(bufnr)
  if peer then
    for _, win in ipairs(windows_for_buffer(peer)) do
      set_window_lnum(win, row)
    end
  end
end

---@param bufnr integer
---@param direction integer
local function goto_anchor(bufnr, direction)
  local info = pane_info[bufnr]
  if not info then
    return
  end
  local anchors = sorted_anchors(info.anchors)
  if #anchors == 0 then
    return
  end
  local win = current_or_first_window_for_buffer(bufnr) or vim.api.nvim_get_current_win()
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if direction > 0 then
    for _, anchor in ipairs(anchors) do
      if anchor > row then
        target = anchor
        break
      end
    end
    if not target then
      target = anchors[1]
      notify('wrapped to first hunk', vim.log.levels.INFO)
    end
  else
    for i = #anchors, 1, -1 do
      if anchors[i] < row then
        target = anchors[i]
        break
      end
    end
    if not target then
      target = anchors[#anchors]
      notify('wrapped to last hunk', vim.log.levels.INFO)
    end
  end
  move_pair_to_row(bufnr, target)
end

---@param bufnr integer
---@param source diffs.SplitEndpointSource
---@param lines string[]
---@param info diffs.SplitPaneInfo
---@param hunks diffs.DiffHunk[]
local function apply_buffer_lines(bufnr, source, lines, info, hunks)
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  paint_pane(bufnr, source, info, hunks)
  set_buffer_options(bufnr, source.filetype)
  set_keymaps(bufnr)
  ensure_pair_cleanup(bufnr)
end

---@param bufnr integer
local function refresh_visible_pair_options(bufnr)
  for _, buf in ipairs({ bufnr, split_peer(bufnr) }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(windows_for_buffer(buf)) do
        set_pair_window_options(win)
      end
    end
  end
end

---@param source diffs.SplitEndpointSource
local function delete_existing_buffer(source)
  local existing = vim.fn.bufnr(buffer_name(source))
  if existing == -1 or not vim.api.nvim_buf_is_valid(existing) then
    return
  end

  M.close_pair(existing)
  if vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
end

---@param left_source diffs.SplitEndpointSource
---@param right_source diffs.SplitEndpointSource
local function delete_existing_pair_buffers(left_source, right_source)
  delete_existing_buffer(left_source)
  delete_existing_buffer(right_source)
end

---@param filepath string
---@return integer?
local function find_window_for_file(filepath)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(buf) == filepath then
        return win
      end
    end
  end
  return nil
end

---@param repo_root string
---@param path string
---@return string
local function resolve_worktree_path(repo_root, path)
  if path:sub(1, 1) == '/' then
    return path
  end
  return abs_path(repo_root, path)
end

---@param buffers table<integer, boolean>
---@param bufnr integer?
local function add_valid_buffer(buffers, bufnr)
  if type(bufnr) == 'number' and vim.api.nvim_buf_is_valid(bufnr) then
    buffers[bufnr] = true
  end
end

---@param win integer
---@param buffers table<integer, boolean>
---@return boolean
local function window_has_buffer(win, buffers)
  return buffers[vim.api.nvim_win_get_buf(win)] == true
end

---@param bufnr integer
---@return table<integer, boolean>
local function pair_buffers_for(bufnr)
  local buffers = {}
  add_valid_buffer(buffers, bufnr)
  add_valid_buffer(buffers, split_peer(bufnr))
  return buffers
end

---@param buffers table<integer, boolean>
---@return integer[], integer[]
local function tab_windows_for_buffers(buffers)
  local pair_wins = {}
  local non_pair_wins = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      if window_has_buffer(win, buffers) then
        pair_wins[#pair_wins + 1] = win
      else
        non_pair_wins[#non_pair_wins + 1] = win
      end
    end
  end
  return pair_wins, non_pair_wins
end

---@param bufnr integer
---@param keep_win integer
---@return table<integer, boolean>?
local function close_pair_into_window(bufnr, keep_win)
  if not vim.api.nvim_win_is_valid(keep_win) then
    return nil
  end

  local buffers = pair_buffers_for(bufnr)
  if vim.tbl_isempty(buffers) then
    return nil
  end

  local keep_is_pair_win = false
  local pair_wins = tab_windows_for_buffers(buffers)
  for _, win in ipairs(pair_wins) do
    keep_is_pair_win = keep_is_pair_win or win == keep_win
  end
  if not keep_is_pair_win then
    return nil
  end

  for buf in pairs(buffers) do
    closing_buffers[buf] = true
  end

  for _, win in ipairs(pair_wins) do
    clear_pair_window_options(win)
  end
  vim.api.nvim_set_current_win(keep_win)
  for _, win in ipairs(pair_wins) do
    if win ~= keep_win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  return buffers
end

---@param buffers table<integer, boolean>
local function delete_pair_buffers(buffers)
  for buf in pairs(buffers) do
    clear_pair_tracking(buf, true)
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    closing_buffers[buf] = nil
  end
end

---@param spec diffs.DiffSpec
---@param old_lines string[]
---@param new_lines string[]
---@return diffs.DifftAlignment? difftastic alignment when enabled/available, else nil
local function difft_alignment(spec, old_lines, new_lines)
  if not difftastic.available() then
    return nil
  end
  local relpath = (spec and spec.scope and spec.scope.path) or 'file'
  return (difftastic.align(old_lines, new_lines, relpath))
end

---@param old_lines string[]
---@param new_lines string[]
---@param hunks diffs.DiffHunk[]
---@param change_bar? string
---@param difft? diffs.DifftAlignment precomputed difftastic alignment
---@return diffs.SplitAlignment, diffs.SplitPaneInfo, diffs.SplitPaneInfo
local function build_pane_infos(old_lines, new_lines, hunks, change_bar, difft)
  local use_difft = difft ~= nil and difft.changed
  local alignment = use_difft and difft or split_align.align(old_lines, new_lines, hunks)
  local max_lnum = math.max(#old_lines, #new_lines, 1)
  local rail_width = math.max(2, #tostring(max_lnum))
  local bar = change_bar or default_change_bar
  local left_info = {
    rows = alignment.left_rows,
    side = 'left',
    rail_width = rail_width,
    change_bar = bar,
    anchors = alignment.anchors,
    difft_intra = use_difft and difft.left_intra or nil,
  }
  local right_info = {
    rows = alignment.right_rows,
    side = 'right',
    rail_width = rail_width,
    change_bar = bar,
    anchors = alignment.anchors,
    difft_intra = use_difft and difft.right_intra or nil,
  }
  return alignment, left_info, right_info
end

---@param opts diffs.SplitOpenOpts
---@return { left_buf: integer, right_buf: integer, left_win: integer, right_win: integer }?, string?
function M.open(opts)
  local spec = diffspec.new(opts.spec)
  local filetype = opts.filetype
  local path = spec.scope.path
  local base_source = {
    repo_root = opts.repo_root,
    spec = spec,
    path = path,
    filetype = filetype,
    quickfix = opts.quickfix,
  }

  local left_source =
    generated.split_endpoint_source(vim.tbl_extend('force', base_source, { side = 'left' }))
  local right_source =
    generated.split_endpoint_source(vim.tbl_extend('force', base_source, { side = 'right' }))
  local old_content, left_err =
    endpoint_lines(left_source, { worktree_lines = opts.worktree_lines })
  if not old_content then
    return nil, left_err
  end
  local new_content, right_err =
    endpoint_lines(right_source, { worktree_lines = opts.worktree_lines })
  if not new_content then
    return nil, right_err
  end
  local split_hunks = split_hunks_for(opts.diff_lines, spec)
  local difft = difft_alignment(spec, old_content, new_content)
  if difft and not difft.changed then
    log.notify('difftastic: no structural changes (formatting only)', vim.log.levels.INFO)
  end
  local alignment, left_info, right_info =
    build_pane_infos(old_content, new_content, split_hunks, opts.change_bar, difft)

  local reuse = opts.reuse_wins
  local invoking_win = vim.api.nvim_get_current_win()

  delete_existing_pair_buffers(left_source, right_source)

  local reusing = reuse ~= nil
    and vim.api.nvim_win_is_valid(reuse.left)
    and vim.api.nvim_win_is_valid(reuse.right)

  ---@type integer[]
  local stale_buffers = {}
  local left_win, right_win
  if reusing then
    left_win, right_win = reuse.left, reuse.right
    for _, win in ipairs({ left_win, right_win }) do
      local buf = vim.api.nvim_win_get_buf(win)
      stale_buffers[#stale_buffers + 1] = buf
      closing_buffers[buf] = true
    end
  else
    if vim.api.nvim_win_is_valid(invoking_win) then
      vim.api.nvim_set_current_win(invoking_win)
    end
    left_win = vim.api.nvim_get_current_win()
    vim.cmd('rightbelow vsplit')
    right_win = vim.api.nvim_get_current_win()
  end

  local left_buf = create_buffer(left_source, alignment.left_lines, left_info, split_hunks)
  local right_buf = create_buffer(right_source, alignment.right_lines, right_info, split_hunks)

  vim.api.nvim_win_set_buf(left_win, left_buf)
  vim.api.nvim_win_set_buf(right_win, right_buf)
  set_peers(left_buf, right_buf)
  track_split_window(left_win, left_buf)
  track_split_window(right_win, right_buf)

  set_pair_window_options(left_win)
  set_pair_window_options(right_win)
  vim.api.nvim_set_current_win(right_win)
  lists.set_for_split_pair({
    title = opts.title or ('diff: ' .. diffspec.label(spec)),
    left_buf = left_buf,
    right_buf = right_buf,
    left_win = left_win,
    right_win = right_win,
    hunks = split_hunks,
    anchors = alignment.anchors,
    quickfix = opts.quickfix,
  })

  if opts.hunk_index and alignment.anchors[opts.hunk_index] then
    move_pair_to_row(right_buf, alignment.anchors[opts.hunk_index])
  end

  for _, buf in ipairs(stale_buffers) do
    clear_pair_tracking(buf, true)
    if buf ~= left_buf and buf ~= right_buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    closing_buffers[buf] = nil
  end

  log.dbg('opened split diff buffers %d/%d for %s', left_buf, right_buf, diffspec.label(spec))
  return {
    left_buf = left_buf,
    right_buf = right_buf,
    left_win = left_win,
    right_win = right_win,
  },
    nil
end

---@param source table
---@return diffs.SplitEndpointSource
function normalize_source(source)
  return {
    version = 1,
    kind = 'split_endpoint',
    repo_root = source.repo_root,
    spec = diffspec.new(source.spec),
    side = source.side,
    path = source.path,
    filetype = source.filetype,
    quickfix = source.quickfix,
  }
end

---@param bufnr integer
---@param source table
---@param opts? { change_bar?: string }
---@return boolean, string?
function M.read_buffer(bufnr, source, opts)
  opts = opts or {}
  source = normalize_source(source)

  local peer = split_peer(bufnr)
  if not peer or peer == bufnr then
    detach_split_endpoint(bufnr)
    return false, 'cannot reload split endpoint without a valid peer'
  end

  local peer_source = peer and buffer_source(peer) or nil
  if peer and not peer_source then
    detach_split_endpoint(bufnr)
    return false, 'cannot reload split peer without source metadata'
  end

  local current_lines, current_err = endpoint_lines(source)
  if not current_lines then
    return false, current_err
  end

  local peer_lines
  if peer_source then
    local peer_err
    peer_lines, peer_err = endpoint_lines(peer_source)
    if not peer_lines then
      return false, peer_err
    end
  end

  local split_hunks
  if peer_source then
    local diff_lines, diff_err = render.file(source.spec, source.repo_root)
    if not diff_lines then
      return false, diff_err
    end
    split_hunks = split_hunks_for(diff_lines, source.spec)
  end

  if not (peer_source and peer_lines) then
    return false, 'cannot reload split pair without peer content'
  end

  local left_buf = source.side == 'left' and bufnr or peer
  local right_buf = source.side == 'right' and bufnr or peer
  local left_source = source.side == 'left' and source or peer_source
  local right_source = source.side == 'right' and source or peer_source
  local old_content = source.side == 'left' and current_lines or peer_lines
  local new_content = source.side == 'right' and current_lines or peer_lines

  local difft = difft_alignment(source.spec, old_content, new_content)
  local alignment, left_info, right_info =
    build_pane_infos(old_content, new_content, split_hunks or {}, opts.change_bar, difft)
  apply_buffer_lines(left_buf, left_source, alignment.left_lines, left_info, split_hunks or {})
  apply_buffer_lines(right_buf, right_source, alignment.right_lines, right_info, split_hunks or {})
  set_peers(left_buf, right_buf)
  refresh_visible_pair_options(left_buf)
  lists.set_for_split_pair({
    title = 'diff: ' .. diffspec.label(source.spec),
    left_buf = left_buf,
    right_buf = right_buf,
    hunks = split_hunks,
    anchors = alignment.anchors,
    quickfix = source.quickfix,
  })
  return true, nil
end

---@param bufnr? integer
---@param keep_win integer
---@return table<integer, boolean>?
function M.close_pair_into_window(bufnr, keep_win)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if type(keep_win) ~= 'number' then
    return nil
  end
  return close_pair_into_window(bufnr, keep_win)
end

---@param buffers table<integer, boolean>
function M.delete_pair_buffers(buffers)
  delete_pair_buffers(buffers)
end

---@param bufnr? integer
---@return boolean
function M.close_pair(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local buffers = pair_buffers_for(bufnr)
  if vim.tbl_isempty(buffers) then
    return false
  end

  for buf in pairs(buffers) do
    if closing_buffers[buf] then
      return false
    end
  end

  local pair_wins, non_pair_wins = tab_windows_for_buffers(buffers)

  for _, win in ipairs(pair_wins) do
    split_windows[win] = nil
  end
  for buf in pairs(buffers) do
    closing_buffers[buf] = true
  end

  local keep_win
  if #non_pair_wins == 0 then
    local current_win = vim.api.nvim_get_current_win()
    for _, win in ipairs(pair_wins) do
      if win == current_win then
        keep_win = win
        break
      end
    end
    keep_win = keep_win or pair_wins[1]
    if keep_win and vim.api.nvim_win_is_valid(keep_win) then
      vim.api.nvim_set_current_win(keep_win)
      clear_pair_window_options(keep_win)
      vim.cmd.enew()
    end
  end

  for _, win in ipairs(pair_wins) do
    if win ~= keep_win then
      clear_pair_window_options(win)
    end
    if win ~= keep_win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  delete_pair_buffers(buffers)

  local focus_win = non_pair_wins[1] or keep_win
  if focus_win and vim.api.nvim_win_is_valid(focus_win) then
    vim.api.nvim_set_current_win(focus_win)
  end

  return true
end

---@param win integer
---@return boolean
function M.release_pair_window_options(win)
  if not vim.api.nvim_win_is_valid(win) or not pair_window_options[win] then
    return false
  end

  clear_pair_window_options(win)
  return true
end

---@param rows diffs.SplitRow[]
---@param cursor_row integer
---@param lnum_field "old_lnum"|"new_lnum"
---@return diffs.SplitRow?
local function nearest_non_filler_row(rows, cursor_row, lnum_field)
  for offset = 0, #rows do
    local above = rows[cursor_row - offset]
    if above and above.kind ~= 'filler' and above[lnum_field] then
      return above
    end
    local below = rows[cursor_row + offset]
    if below and below.kind ~= 'filler' and below[lnum_field] then
      return below
    end
  end
  return nil
end

---@param bufnr integer
---@return boolean
function M.open_source(bufnr)
  local source = buffer_source(bufnr)
  if not source then
    notify('missing split diff source metadata', vim.log.levels.WARN)
    return false
  end

  local endpoint = side_endpoint(source.spec, source.side)
  if endpoint.kind ~= diffspec.endpoint_kind.worktree then
    if endpoint.kind == diffspec.endpoint_kind.index then
      notify('cannot open index-backed split endpoint as a worktree file', vim.log.levels.WARN)
    else
      notify(
        'cannot open read-only tree-backed split endpoint as a worktree file',
        vim.log.levels.WARN
      )
    end
    return false
  end

  local source_win = current_or_first_window_for_buffer(bufnr)
  if not source_win then
    notify('cannot open hidden split endpoint as a source file', vim.log.levels.WARN)
    return false
  end

  local filepath = resolve_worktree_path(source.repo_root, source.path)
  local cursor_row = vim.api.nvim_win_get_cursor(source_win)[1]
  local info = pane_info[bufnr]
  local target_lnum = cursor_row
  if info and info.rows then
    local lnum_field = side_config[source.side].lnum
    local row = nearest_non_filler_row(info.rows, cursor_row, lnum_field)
    target_lnum = (row and row[lnum_field]) or cursor_row
  end
  local existing_win = find_window_for_file(filepath)
  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
  else
    local buffers = close_pair_into_window(bufnr, source_win)
    if not buffers then
      notify('cannot close split pair before opening source file', vim.log.levels.WARN)
      return false
    end
    vim.cmd.edit(vim.fn.fnameescape(filepath))
    delete_pair_buffers(buffers)
  end
  local lnum = math.max(1, math.min(target_lnum, vim.api.nvim_buf_line_count(0)))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  return true
end

---@param bufnr integer
function M.goto_next(bufnr)
  goto_anchor(bufnr, 1)
end

---@param bufnr integer
function M.goto_prev(bufnr)
  goto_anchor(bufnr, -1)
end

---@param bufnr integer
---@param hunk_index integer?
---@return boolean
function M.move_pair_to_hunk_index(bufnr, hunk_index)
  if type(hunk_index) ~= 'number' then
    return false
  end

  local info = pane_info[bufnr]
  local row = info and info.anchors and info.anchors[hunk_index]
  if not row then
    return false
  end

  move_pair_to_row(bufnr, row)
  return true
end

---@param bufnr integer
function M.sync_cursor_to_hunk(bufnr)
  local win = current_or_first_window_for_buffer(bufnr)
  if not win then
    return
  end
  move_pair_to_row(bufnr, vim.api.nvim_win_get_cursor(win)[1])
end

M._test = {
  buffer_name = buffer_name,
  endpoint_lines = endpoint_lines,
  split_hunks_for = split_hunks_for,
}

return M
