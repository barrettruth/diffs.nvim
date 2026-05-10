local M = {}

local hunk_model = require('diffs.hunks')

local generated_list_autocmds = {}
local generated_list_state = {}
local quickfix_keymap_autocmd
---@type fun(item: table?)?
local generated_jump_callback
local quickfix_enter_desc = 'Open quickfix item'

local group = vim.api.nvim_create_augroup('diffs_generated_lists', { clear = false })

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
---@return diffs.DiffSpec?
local function buffer_diff_spec(bufnr)
  return get_buf_var(bufnr, 'diffs_spec')
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

---@param win integer
---@return integer?
local function win_number(win)
  local nr = vim.fn.win_id2win(win)
  if nr > 0 then
    return nr
  end
  return nil
end

---@param hunk diffs.GdiffHunk
---@return string
local function hunk_file(hunk)
  return hunk.file or hunk.path or '(unknown)'
end

---@param hunk diffs.GdiffHunk
---@return integer
local function file_lnum(hunk)
  return hunk.file_header_range and hunk.file_header_range.start or hunk.buffer_range.start
end

---@param line string
---@return string?
local function diff_file(line)
  local old_path, new_path = line:match('^diff %-%-git a/(.-) b/(.+)$')
  return new_path or old_path
end

---@param hunk diffs.GdiffHunk
---@return integer, integer
local function hunk_stats(hunk)
  local adds = 0
  local dels = 0
  for _, line in ipairs(hunk.lines or {}) do
    if line.kind == 'add' then
      adds = adds + 1
    elseif line.kind == 'delete' then
      dels = dels + 1
    end
  end
  return adds, dels
end

---@param entries table[]
---@param by_file table<string, table>
---@param file string
---@param lnum integer
---@return table
local function ensure_file_entry(entries, by_file, file, lnum)
  local entry = by_file[file]
  if entry then
    entry.lnum = math.min(entry.lnum, lnum)
    return entry
  end

  entry = {
    file = file,
    lnum = lnum,
    adds = 0,
    dels = 0,
    hunks = {},
  }
  by_file[file] = entry
  entries[#entries + 1] = entry
  return entry
end

---@param hunks diffs.GdiffHunk[]
---@param diff_lines? string[]
---@return table[]
local function file_entries(hunks, diff_lines)
  local by_file = {}
  local entries = {}
  for lnum, line in ipairs(diff_lines or {}) do
    local file = diff_file(line)
    if file then
      ensure_file_entry(entries, by_file, file, lnum)
    end
  end

  for _, hunk in ipairs(hunks) do
    local file = hunk_file(hunk)
    local entry = ensure_file_entry(entries, by_file, file, file_lnum(hunk))
    local adds, dels = hunk_stats(hunk)
    entry.adds = entry.adds + adds
    entry.dels = entry.dels + dels
    entry.hunks[#entry.hunks + 1] = hunk
  end
  return entries
end

---@param entries table[]
local function format_file_text(entries)
  local max_fname = 0
  local max_add, max_del = 0, 0
  for _, entry in ipairs(entries) do
    max_fname = math.max(max_fname, #entry.file)
    if entry.adds > 0 then
      max_add = math.max(max_add, #tostring(entry.adds) + 1)
    end
    if entry.dels > 0 then
      max_del = math.max(max_del, #tostring(entry.dels) + 1)
    end
  end

  for _, entry in ipairs(entries) do
    local padded = entry.file .. string.rep(' ', max_fname - #entry.file)
    local parts = { padded }
    if max_add > 0 then
      parts[#parts + 1] = entry.adds > 0 and string.format('%' .. max_add .. 's', '+' .. entry.adds)
        or string.rep(' ', max_add)
    end
    if max_del > 0 then
      parts[#parts + 1] = entry.dels > 0 and string.format('%' .. max_del .. 's', '-' .. entry.dels)
        or string.rep(' ', max_del)
    end
    entry.text = table.concat(parts, ' '):gsub('%s+$', '')
  end
end

---@param bufnr integer
---@param entries table[]
---@return table[]
local function quickfix_items(bufnr, entries)
  format_file_text(entries)
  local items = {}
  for _, entry in ipairs(entries) do
    items[#items + 1] = {
      bufnr = bufnr,
      lnum = entry.lnum,
      col = 1,
      text = entry.text,
      user_data = {
        diffs = {
          kind = 'file',
          file = entry.file,
        },
      },
    }
  end
  return items
end

---@param hunks diffs.GdiffHunk[]
---@param entries table[]
---@param lnum integer
---@return string?
local function file_at_lnum(hunks, entries, lnum)
  entries = entries or file_entries(hunks)
  if #entries == 0 then
    return nil
  end

  local selected = entries[1].file
  for _, entry in ipairs(entries) do
    if lnum >= entry.lnum then
      selected = entry.file
    else
      break
    end
  end
  return selected
end

---@param bufnr integer
---@param hunks diffs.GdiffHunk[]
---@param file string?
---@return table[]
local function loclist_items(bufnr, hunks, file)
  local file_hunk_count = {}
  local items = {}
  for _, hunk in ipairs(hunks) do
    local hfile = hunk_file(hunk)
    if not file or hfile == file then
      file_hunk_count[hfile] = (file_hunk_count[hfile] or 0) + 1
      items[#items + 1] = {
        bufnr = bufnr,
        lnum = hunk.buffer_range.start,
        col = 1,
        text = ('%s (hunk %d) %s'):format(hfile, file_hunk_count[hfile], hunk.header),
        user_data = {
          diffs = {
            kind = 'hunk',
            file = hfile,
            hunk = hunk.index,
          },
        },
      }
    end
  end
  return items
end

---@param hunks diffs.GdiffHunk[]
---@param lnum integer
---@return diffs.GdiffHunk?
local function hunk_at_lnum(hunks, lnum)
  for _, hunk in ipairs(hunks) do
    if lnum >= hunk.buffer_range.start and lnum <= hunk.buffer_range.finish then
      return hunk
    end
  end
  return nil
end

---@param hunks diffs.GdiffHunk[]
---@param index integer?
---@return diffs.GdiffHunk?
local function hunk_by_index(hunks, index)
  if type(index) ~= 'number' then
    return nil
  end
  for _, hunk in ipairs(hunks) do
    if hunk.index == index then
      return hunk
    end
  end
  return nil
end

---@param hunks diffs.GdiffHunk[]
---@param target diffs.GdiffHunk?
---@return integer?
local function file_hunk_index(hunks, target)
  if not target then
    return nil
  end

  local count = 0
  local file = hunk_file(target)
  for _, hunk in ipairs(hunks) do
    if hunk_file(hunk) == file then
      count = count + 1
    end
    if hunk == target then
      return count
    end
  end
  return nil
end

---@param item table?
---@return table?
local function item_diffs_data(item)
  if type(item) ~= 'table' or type(item.user_data) ~= 'table' then
    return nil
  end

  local diffs = item.user_data.diffs
  if type(diffs) == 'table' then
    return diffs
  end
  return nil
end

---@param item table?
---@return table?, string?
local function selection_from_item(item)
  local data = item_diffs_data(item)
  if not data or (data.kind ~= 'file' and data.kind ~= 'hunk') then
    return nil, 'quickfix item is not a generated diff file'
  end
  if type(item.bufnr) ~= 'number' or item.bufnr <= 0 then
    return nil, 'quickfix item is missing a generated buffer'
  end
  if type(data.file) ~= 'string' or data.file == '' then
    return nil, 'quickfix item is missing a generated diff file'
  end

  local state = generated_list_state[item.bufnr]
  local hunk = state and hunk_by_index(state.hunks, data.hunk) or nil
  return {
    bufnr = item.bufnr,
    file = data.file,
    lnum = item.lnum,
    hunk = hunk,
    hunk_index = state and file_hunk_index(state.hunks, hunk) or nil,
  },
    nil
end

---@param title string
---@param items table[]
local function set_quickfix(title, items)
  M.ensure_quickfix_keymap()
  vim.fn.setqflist({}, ' ', {
    title = title,
    items = items,
    quickfixtextfunc = 'v:lua._diffs_qftf',
  })
end

---@param win integer
---@param title string
---@param items table[]
local function set_loclist(win, title, items)
  local nr = win_number(win)
  if not nr then
    return
  end
  M.ensure_quickfix_keymap()
  vim.fn.setloclist(nr, {}, ' ', {
    title = title,
    items = items,
    quickfixtextfunc = 'v:lua._diffs_qftf',
  })
end

---@param bufnr integer
---@param win integer
---@param force? boolean
local function refresh_loclist_for_window(bufnr, win, force)
  local state = generated_list_state[bufnr]
  if not state or not vim.api.nvim_win_is_valid(win) then
    return
  end
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local file = file_at_lnum(state.hunks, state.entries, cursor)
  local cache = state.win_files or {}
  state.win_files = cache
  if not force and cache[win] == file then
    return
  end
  cache[win] = file

  set_loclist(win, state.loclist_title, loclist_items(bufnr, state.hunks, file))
end

---@param bufnr integer
local function refresh_current_loclist(bufnr)
  local win = vim.api.nvim_get_current_win()
  refresh_loclist_for_window(bufnr, win, false)
end

---@param bufnr integer
local function ensure_generated_autocmds(bufnr)
  if generated_list_autocmds[bufnr] then
    return
  end

  local ids = {}
  ids[#ids + 1] = vim.api.nvim_create_autocmd({ 'BufEnter', 'CursorMoved' }, {
    group = group,
    buffer = bufnr,
    callback = function(args)
      refresh_current_loclist(args.buf)
    end,
  })
  ids[#ids + 1] = vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = bufnr,
    once = true,
    callback = function(args)
      generated_list_state[args.buf] = nil
      generated_list_autocmds[args.buf] = nil
    end,
  })
  generated_list_autocmds[bufnr] = ids
end

---@param item table?
local function sync_split_item(item)
  if type(item) ~= 'table' or type(item.bufnr) ~= 'number' then
    return
  end

  local source = get_buf_var(item.bufnr, 'diffs_source')
  if type(source) ~= 'table' or source.kind ~= 'split_endpoint' then
    return
  end

  require('diffs.split').sync_cursor_to_hunk(item.bufnr)
end

---@param info table
---@return table[]
local function quickfix_text_items(info)
  if info.quickfix == 1 then
    return vim.fn.getqflist({ id = info.id, items = 0 }).items
  end
  return vim.fn.getloclist(info.winid or 0, { id = info.id, items = 0 }).items
end

---@return table?, boolean
local function current_quickfix_item()
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  if type(info) ~= 'table' or info.quickfix ~= 1 then
    return nil, false
  end

  local is_loclist = info.loclist == 1
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local items = is_loclist and vim.fn.getloclist(0, { items = 0 }).items
    or vim.fn.getqflist({ items = 0 }).items
  return items[row], is_loclist
end

---@param bufnr integer
---@param explicit_lnum integer?
---@return integer
local function selection_lnum(bufnr, explicit_lnum)
  if type(explicit_lnum) == 'number' then
    return explicit_lnum
  end

  if vim.api.nvim_get_current_buf() == bufnr then
    return vim.api.nvim_win_get_cursor(0)[1]
  end

  local win = windows_for_buffer(bufnr)[1]
  if win then
    return vim.api.nvim_win_get_cursor(win)[1]
  end

  return 1
end

local function jump_current_quickfix_item()
  local item, is_loclist = current_quickfix_item()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local command = is_loclist and 'll' or 'cc'
  local jumped = false
  if type(item) == 'table' and type(item.bufnr) == 'number' then
    local item_win = windows_for_buffer(item.bufnr)[1]
    if item_win then
      if generated_jump_callback then
        generated_jump_callback(item)
      end
      local lnum = math.max(1, math.min(item.lnum or 1, vim.api.nvim_buf_line_count(item.bufnr)))
      local col = math.max(0, (item.col or 1) - 1)
      vim.api.nvim_set_current_win(item_win)
      vim.api.nvim_win_set_cursor(item_win, { lnum, col })
      jumped = true
    end
  end
  if not jumped then
    vim.cmd(command .. ' ' .. row)
  end
  sync_split_item(item)
  if generated_jump_callback then
    generated_jump_callback(item)
  end
end

---@param callback fun(item: table?)?
function M.set_generated_jump_callback(callback)
  generated_jump_callback = callback
end

---@class diffs.GeneratedFileSelectionOpts
---@field bufnr? integer
---@field lnum? integer
---@field item? table

---@class diffs.GeneratedFileSelection
---@field bufnr integer
---@field file string
---@field lnum integer?
---@field hunk? diffs.GdiffHunk
---@field hunk_index? integer

---@param opts? diffs.GeneratedFileSelectionOpts
---@return diffs.GeneratedFileSelection?, string?
function M.selected_generated_file(opts)
  opts = opts or {}

  if opts.item then
    return selection_from_item(opts.item)
  end

  if not opts.bufnr and not opts.lnum then
    local item = current_quickfix_item()
    if item then
      return selection_from_item(item)
    end
  end

  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local state = generated_list_state[bufnr]
  if not state then
    return nil, 'current buffer has no generated diff file index'
  end

  local lnum = selection_lnum(bufnr, opts.lnum)
  local file = file_at_lnum(state.hunks, state.entries, lnum)
  if not file then
    return nil, 'no generated diff file selected'
  end

  local hunk = hunk_at_lnum(state.hunks, lnum)
  return {
    bufnr = bufnr,
    file = file,
    lnum = lnum,
    hunk = hunk,
    hunk_index = file_hunk_index(state.hunks, hunk),
  },
    nil
end

---@param bufnr integer
---@return table?
local function enter_keymap(bufnr)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
    if keymap.lhs == '<CR>' then
      return keymap
    end
  end
  return nil
end

---@param bufnr integer
local function set_quickfix_keymap(bufnr)
  local existing = enter_keymap(bufnr)
  if existing and existing.desc ~= quickfix_enter_desc then
    return
  end
  vim.keymap.set('n', '<CR>', jump_current_quickfix_item, {
    buffer = bufnr,
    desc = quickfix_enter_desc,
  })
end

function M.ensure_quickfix_keymap()
  if quickfix_keymap_autocmd then
    return
  end

  quickfix_keymap_autocmd = vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'qf',
    callback = function(args)
      set_quickfix_keymap(args.buf)
    end,
  })

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_get_option_value('filetype', { buf = bufnr }) == 'qf'
    then
      set_quickfix_keymap(bufnr)
    end
  end
end

-- selene: allow(global_usage)
function _G._diffs_qftf(info)
  local items = quickfix_text_items(info)
  local max_lnum = 0
  for i = info.start_idx, info.end_idx do
    local e = items[i]
    if e and e.lnum > 0 then
      max_lnum = math.max(max_lnum, #tostring(e.lnum))
    end
  end
  local lnum_fmt = '%' .. math.max(max_lnum, 1) .. 'd'
  local lines = {}
  for i = info.start_idx, info.end_idx do
    local e = items[i] or {}
    local text = e.text or ''
    if max_lnum > 0 and e.lnum and e.lnum > 0 then
      lines[#lines + 1] = ('%s  %s'):format(lnum_fmt:format(e.lnum), text)
    else
      lines[#lines + 1] = text
    end
  end
  return lines
end

---@param bufnr integer
---@param diff_lines string[]
---@param opts? { title?: string, loclist_title?: string, diff_spec?: diffs.DiffSpec }
function M.set_for_unified_buffer(bufnr, diff_lines, opts)
  opts = opts or {}
  local diff_spec = opts.diff_spec or buffer_diff_spec(bufnr)
  local hunks = hunk_model.parse(diff_lines, diff_spec)
  local entries = file_entries(hunks, diff_lines)
  local title = opts.title or 'diffs'
  local loclist_title = opts.loclist_title or (title .. ' hunks')

  generated_list_state[bufnr] = {
    hunks = hunks,
    entries = entries,
    loclist_title = loclist_title,
    win_files = {},
  }
  ensure_generated_autocmds(bufnr)

  set_quickfix(title, quickfix_items(bufnr, entries))
  for _, win in ipairs(windows_for_buffer(bufnr)) do
    refresh_loclist_for_window(bufnr, win, true)
  end
end

---@param hunk diffs.GdiffHunk
---@param side "left"|"right"
---@return integer
local function split_hunk_lnum(hunk, side)
  local range = side == 'left' and hunk.old_range or hunk.new_range
  return math.max(1, range.start)
end

---@param hunk diffs.GdiffHunk
---@param side "left"|"right"
---@return "left"|"right", integer
local function split_target(hunk, side)
  local range = side == 'left' and hunk.old_range or hunk.new_range
  if range.count > 0 then
    return side, split_hunk_lnum(hunk, side)
  end

  local fallback_side = side == 'left' and 'right' or 'left'
  return fallback_side, split_hunk_lnum(hunk, fallback_side)
end

---@param left_buf integer
---@param right_buf integer
---@param hunks diffs.GdiffHunk[]
---@param side "left"|"right"
---@return table[]
local function split_loclist_items(left_buf, right_buf, hunks, side)
  local items = {}
  for i, hunk in ipairs(hunks) do
    local target_side, target_lnum = split_target(hunk, side)
    items[#items + 1] = {
      bufnr = target_side == 'left' and left_buf or right_buf,
      lnum = target_lnum,
      col = 1,
      text = ('%s (hunk %d) %s'):format(hunk_file(hunk), i, hunk.header),
      user_data = {
        diffs = {
          kind = 'split_hunk',
          file = hunk_file(hunk),
          hunk = i,
          side = side,
        },
      },
    }
  end
  return items
end

---@param opts { left_buf: integer, right_buf: integer, hunks: diffs.GdiffHunk[] }
---@return table[]
local function split_quickfix_items(opts)
  local entries = file_entries(opts.hunks)
  format_file_text(entries)
  local items = {}
  for _, entry in ipairs(entries) do
    local first_hunk = entry.hunks[1]
    local target_side = 'right'
    local target_lnum = entry.lnum
    if first_hunk then
      target_side, target_lnum = split_target(first_hunk, 'right')
    end
    items[#items + 1] = {
      bufnr = target_side == 'left' and opts.left_buf or opts.right_buf,
      lnum = target_lnum,
      col = 1,
      text = entry.text,
      user_data = {
        diffs = {
          kind = 'file',
          file = entry.file,
        },
      },
    }
  end
  return items
end

---@param opts { title: string, loclist_title?: string, left_buf: integer, right_buf: integer, left_win?: integer, right_win?: integer, hunks: diffs.GdiffHunk[], quickfix?: boolean }
function M.set_for_split_pair(opts)
  local title = opts.title
  local loclist_title = opts.loclist_title or (title .. ' hunks')

  if opts.quickfix ~= false then
    set_quickfix(title, split_quickfix_items(opts))
  end
  for _, win in ipairs(opts.left_win and { opts.left_win } or windows_for_buffer(opts.left_buf)) do
    set_loclist(
      win,
      loclist_title,
      split_loclist_items(opts.left_buf, opts.right_buf, opts.hunks, 'left')
    )
  end
  for _, win in ipairs(opts.right_win and { opts.right_win } or windows_for_buffer(opts.right_buf)) do
    set_loclist(
      win,
      loclist_title,
      split_loclist_items(opts.left_buf, opts.right_buf, opts.hunks, 'right')
    )
  end
end

M._test = {
  file_at_lnum = file_at_lnum,
  file_entries = file_entries,
  hunk_at_lnum = hunk_at_lnum,
  loclist_items = loclist_items,
  quickfix_items = quickfix_items,
  selected_generated_file = M.selected_generated_file,
}

return M
