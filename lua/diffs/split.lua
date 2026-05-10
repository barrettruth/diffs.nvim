local M = {}

local diffspec = require('diffs.spec')
local hunk_model = require('diffs.hunks')
local log = require('diffs.log')
local render = require('diffs.render')

local notify = log.notify

---@type table<integer, boolean>
local closing_buffers = {}
---@type table<integer, integer>
local cleanup_autocmds = {}
---@type table<integer, integer>
local peer_buffers = {}
---@type table<integer, table<string, any>>
local pair_window_options = {}

---@class diffs.SplitOpenOpts
---@field spec diffs.DiffSpec
---@field repo_root string
---@field filetype? string
---@field worktree_lines? diffs.ContentLines|string[]
---@field diff_lines? string[]

---@class diffs.SplitEndpointSource
---@field version integer
---@field kind "split_endpoint"
---@field repo_root string
---@field spec diffs.DiffSpec
---@field side "left"|"right"
---@field path string
---@field filetype? string

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
---@return diffs.GdiffHunk[]
local function split_hunks_for(diff_lines, spec)
  if not diff_lines then
    return {}
  end
  return hunk_model.parse(diff_lines, spec)
end

---@param bufnr integer
---@param source diffs.SplitEndpointSource
---@param split_hunks? diffs.GdiffHunk[]
local function set_source_vars(bufnr, source, split_hunks)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', source.repo_root)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_spec', diffspec.new(source.spec))
  vim.api.nvim_buf_set_var(bufnr, 'diffs_source', source)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_split_side', source.side)
  if split_hunks then
    vim.api.nvim_buf_set_var(bufnr, 'diffs_split_hunks', split_hunks)
  else
    pcall(vim.api.nvim_buf_del_var, bufnr, 'diffs_split_hunks')
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

---@param source diffs.SplitEndpointSource
---@param lines string[]
---@param split_hunks? diffs.GdiffHunk[]
---@return integer
local function create_buffer(source, lines, split_hunks)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(bufnr, buffer_name(source))
  set_source_vars(bufnr, source, split_hunks)
  set_buffer_options(bufnr, source.filetype)
  set_keymaps(bufnr)
  return bufnr
end

---@param win integer
local function disable_diff_folds(win)
  vim.api.nvim_set_option_value('foldmethod', 'manual', { win = win })
  vim.api.nvim_set_option_value('foldenable', false, { win = win })
  vim.api.nvim_set_option_value('foldcolumn', '0', { win = win })
end

---@param win integer
local function remember_pair_window_options(win)
  if pair_window_options[win] or not vim.api.nvim_win_is_valid(win) then
    return
  end

  pair_window_options[win] = {
    diff = vim.api.nvim_get_option_value('diff', { win = win }),
    scrollbind = vim.api.nvim_get_option_value('scrollbind', { win = win }),
    cursorbind = vim.api.nvim_get_option_value('cursorbind', { win = win }),
    foldmethod = vim.api.nvim_get_option_value('foldmethod', { win = win }),
    foldenable = vim.api.nvim_get_option_value('foldenable', { win = win }),
    foldcolumn = vim.api.nvim_get_option_value('foldcolumn', { win = win }),
  }
end

---@param win integer
local function set_pair_window_options(win)
  vim.api.nvim_set_option_value('scrollbind', true, { win = win })
  vim.api.nvim_set_option_value('cursorbind', true, { win = win })
  disable_diff_folds(win)
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
  pcall(vim.api.nvim_set_option_value, 'diff', false, { win = win })
  pcall(vim.api.nvim_set_option_value, 'foldenable', true, { win = win })
end

---@param win integer
local function enable_diff(win)
  remember_pair_window_options(win)
  vim.api.nvim_set_current_win(win)
  vim.cmd.diffthis()
  set_pair_window_options(win)
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
      if closing_buffers[bufnr] or not peer then
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
---@return diffs.GdiffHunk[]
local function buffer_split_hunks(bufnr)
  local ok, parsed = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_split_hunks')
  if ok and type(parsed) == 'table' then
    return parsed
  end
  return {}
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

---@param hunk diffs.GdiffHunk
---@param side "left"|"right"
---@return integer
local function hunk_target_lnum(hunk, side)
  local range = side == 'left' and hunk.old_range or hunk.new_range
  return math.max(1, range.start)
end

---@param hunks diffs.GdiffHunk[]
---@param side "left"|"right"
---@param lnum integer
---@return diffs.GdiffHunk?
local function next_hunk(hunks, side, lnum)
  for _, hunk in ipairs(hunks) do
    if hunk_target_lnum(hunk, side) > lnum then
      return hunk
    end
  end
  return hunks[1]
end

---@param hunks diffs.GdiffHunk[]
---@param side "left"|"right"
---@param lnum integer
---@return diffs.GdiffHunk?
local function prev_hunk(hunks, side, lnum)
  for i = #hunks, 1, -1 do
    local hunk = hunks[i]
    if hunk_target_lnum(hunk, side) < lnum then
      return hunk
    end
  end
  return hunks[#hunks]
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

---@param wins integer[]
---@param callback function
local function without_cursorbind(wins, callback)
  local saved = {}
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      saved[win] = vim.api.nvim_get_option_value('cursorbind', { win = win })
      vim.api.nvim_set_option_value('cursorbind', false, { win = win })
    end
  end

  callback()

  for win, value in pairs(saved) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_option_value('cursorbind', value, { win = win })
    end
  end
end

---@param bufnr integer
---@param hunk diffs.GdiffHunk
local function move_pair_to_hunk(bufnr, hunk)
  local source = buffer_source(bufnr)
  if not source then
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local own_wins = windows_for_buffer(bufnr)
  local peer = split_peer(bufnr)
  local peer_source = peer and buffer_source(peer) or nil
  local peer_wins = peer and windows_for_buffer(peer) or {}
  local all_wins = vim.list_extend(vim.deepcopy(own_wins), peer_wins)

  without_cursorbind(all_wins, function()
    for _, win in ipairs(own_wins) do
      set_window_lnum(win, hunk_target_lnum(hunk, source.side))
    end

    if peer and peer_source then
      for _, win in ipairs(peer_wins) do
        set_window_lnum(win, hunk_target_lnum(hunk, peer_source.side))
      end
    end
  end)

  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
  end
end

---@param bufnr integer
---@param source diffs.SplitEndpointSource
---@param lines string[]
---@param split_hunks? diffs.GdiffHunk[]
local function apply_buffer_lines(bufnr, source, lines, split_hunks)
  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  set_source_vars(bufnr, source, split_hunks)
  set_buffer_options(bufnr, source.filetype)
  set_keymaps(bufnr)
  ensure_pair_cleanup(bufnr)
end

---@param bufnr integer
local function refresh_visible_pair_options(bufnr)
  local peer = split_peer(bufnr)
  local current_win = vim.api.nvim_get_current_win()
  for _, buf in ipairs({ bufnr, peer }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      for _, win in ipairs(windows_for_buffer(buf)) do
        enable_diff(win)
      end
    end
  end
  if vim.api.nvim_win_is_valid(current_win) then
    vim.api.nvim_set_current_win(current_win)
    pcall(vim.cmd.diffupdate)
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

---@param opts diffs.SplitOpenOpts
---@return { left_buf: integer, right_buf: integer, left_win: integer, right_win: integer }?, string?
function M.open(opts)
  local spec = diffspec.new(opts.spec)
  local filetype = opts.filetype
  local path = spec.scope.path
  local base_source = {
    version = 1,
    kind = 'split_endpoint',
    repo_root = opts.repo_root,
    spec = spec,
    path = path,
    filetype = filetype,
  }

  local left_source = vim.tbl_extend('force', base_source, { side = 'left' })
  local right_source = vim.tbl_extend('force', base_source, { side = 'right' })
  local left_lines, left_err = endpoint_lines(left_source, { worktree_lines = opts.worktree_lines })
  if not left_lines then
    return nil, left_err
  end
  local right_lines, right_err =
    endpoint_lines(right_source, { worktree_lines = opts.worktree_lines })
  if not right_lines then
    return nil, right_err
  end
  local split_hunks = split_hunks_for(opts.diff_lines, spec)

  local invoking_win = vim.api.nvim_get_current_win()
  delete_existing_pair_buffers(left_source, right_source)
  if vim.api.nvim_win_is_valid(invoking_win) then
    vim.api.nvim_set_current_win(invoking_win)
  end

  local left_buf = create_buffer(left_source, left_lines, split_hunks)
  local right_buf = create_buffer(right_source, right_lines, split_hunks)
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow vsplit')
  local right_win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(left_win, left_buf)
  vim.api.nvim_win_set_buf(right_win, right_buf)
  set_peers(left_buf, right_buf)

  enable_diff(left_win)
  enable_diff(right_win)
  vim.api.nvim_set_current_win(right_win)
  vim.cmd.diffupdate()
  set_pair_window_options(left_win)
  set_pair_window_options(right_win)

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
  }
end

---@param bufnr integer
---@param source table
---@return boolean, string?
function M.read_buffer(bufnr, source)
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

  apply_buffer_lines(bufnr, source, current_lines, split_hunks)
  if peer and peer_source and peer_lines then
    apply_buffer_lines(peer, peer_source, peer_lines, split_hunks)
    if source.side == 'left' then
      set_peers(bufnr, peer)
    else
      set_peers(peer, bufnr)
    end
    refresh_visible_pair_options(bufnr)
  end
  return true, nil
end

---@param bufnr? integer
---@return boolean
function M.close_pair(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local buffers = pair_buffers_for(bufnr)
  if vim.tbl_isempty(buffers) then
    return false
  end

  local pair_wins, non_pair_wins = tab_windows_for_buffers(buffers)

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
  local target_lnum = vim.api.nvim_win_get_cursor(source_win)[1]
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
  local source = buffer_source(bufnr)
  local hunks = buffer_split_hunks(bufnr)
  if not source or #hunks == 0 then
    return
  end

  local win = current_or_first_window_for_buffer(bufnr) or vim.api.nvim_get_current_win()
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local hunk = next_hunk(hunks, source.side, cursor_line)
  if not hunk then
    return
  end
  if hunk == hunks[1] and hunk_target_lnum(hunk, source.side) <= cursor_line then
    notify('wrapped to first hunk', vim.log.levels.INFO)
  end
  move_pair_to_hunk(bufnr, hunk)
end

---@param bufnr integer
function M.goto_prev(bufnr)
  local source = buffer_source(bufnr)
  local hunks = buffer_split_hunks(bufnr)
  if not source or #hunks == 0 then
    return
  end

  local win = current_or_first_window_for_buffer(bufnr) or vim.api.nvim_get_current_win()
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local hunk = prev_hunk(hunks, source.side, cursor_line)
  if not hunk then
    return
  end
  if hunk == hunks[#hunks] and hunk_target_lnum(hunk, source.side) >= cursor_line then
    notify('wrapped to last hunk', vim.log.levels.INFO)
  end
  move_pair_to_hunk(bufnr, hunk)
end

M._test = {
  buffer_name = buffer_name,
  endpoint_lines = endpoint_lines,
  split_hunks_for = split_hunks_for,
}

return M
