local M = {}

local diffspec = require('diffs.spec')
local log = require('diffs.log')
local render = require('diffs.render')

local notify = log.notify

---@class diffs.SplitOpenOpts
---@field spec diffs.DiffSpec
---@field repo_root string
---@field filetype? string
---@field worktree_lines? diffs.ContentLines|string[]

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

---@param bufnr integer
---@param source diffs.SplitEndpointSource
local function set_source_vars(bufnr, source)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', source.repo_root)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_spec', diffspec.new(source.spec))
  vim.api.nvim_buf_set_var(bufnr, 'diffs_source', source)
  vim.api.nvim_buf_set_var(bufnr, 'diffs_split_side', source.side)
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
---@return integer
local function create_buffer(source, lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(bufnr, buffer_name(source))
  set_source_vars(bufnr, source)
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
local function enable_diff(win)
  vim.api.nvim_set_current_win(win)
  vim.cmd.diffthis()
  disable_diff_folds(win)
end

---@param bufnr integer
---@return integer?
local function split_peer(bufnr)
  local ok, peer = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_split_peer')
  if ok and type(peer) == 'number' and vim.api.nvim_buf_is_valid(peer) then
    return peer
  end
  return nil
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

  local left_buf = create_buffer(left_source, left_lines)
  local right_buf = create_buffer(right_source, right_lines)
  local left_win = vim.api.nvim_get_current_win()
  vim.cmd('rightbelow vsplit')
  local right_win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(left_win, left_buf)
  vim.api.nvim_win_set_buf(right_win, right_buf)
  vim.api.nvim_buf_set_var(left_buf, 'diffs_split_peer', right_buf)
  vim.api.nvim_buf_set_var(right_buf, 'diffs_split_peer', left_buf)

  enable_diff(left_win)
  enable_diff(right_win)
  vim.api.nvim_set_current_win(right_win)
  vim.cmd.diffupdate()
  disable_diff_folds(left_win)
  disable_diff_folds(right_win)

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
local function normalize_source(source)
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
  local lines, err = endpoint_lines(source)
  if not lines then
    return false, err
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  set_source_vars(bufnr, source)
  set_buffer_options(bufnr, source.filetype)
  set_keymaps(bufnr)
  return true, nil
end

---@param bufnr? integer
---@return boolean
function M.close_pair(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local buffers = {}
  add_valid_buffer(buffers, bufnr)
  add_valid_buffer(buffers, split_peer(bufnr))
  if vim.tbl_isempty(buffers) then
    return false
  end

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
      vim.cmd.diffoff()
      vim.cmd.enew()
    end
  end

  for _, win in ipairs(pair_wins) do
    if win ~= keep_win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for buf in pairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  local focus_win = non_pair_wins[1] or keep_win
  if focus_win and vim.api.nvim_win_is_valid(focus_win) then
    vim.api.nvim_set_current_win(focus_win)
  end

  return true
end

---@param bufnr integer
---@return boolean
function M.open_source(bufnr)
  local ok, source = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_source')
  if not ok or type(source) ~= 'table' or source.kind ~= 'split_endpoint' then
    notify('missing split diff source metadata', vim.log.levels.WARN)
    return false
  end

  source = normalize_source(source)
  local endpoint = side_endpoint(source.spec, source.side)
  if endpoint.kind ~= diffspec.endpoint_kind.worktree then
    notify('cannot open non-worktree split endpoint as a source file', vim.log.levels.WARN)
    return false
  end

  local filepath = abs_path(source.repo_root, source.path)
  local target_lnum = vim.api.nvim_win_get_cursor(0)[1]
  vim.cmd.edit(vim.fn.fnameescape(filepath))
  local lnum = math.max(1, math.min(target_lnum, vim.api.nvim_buf_line_count(0)))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  return true
end

M._test = {
  buffer_name = buffer_name,
  endpoint_lines = endpoint_lines,
}

return M
