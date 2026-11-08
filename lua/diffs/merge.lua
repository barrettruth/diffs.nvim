local M = {}

local conflict = require('diffs.conflict')
local notify = require('diffs.log').notify
local rails = require('diffs.rails')

---@type table<integer, table<integer, true>>
local resolved_hunks = {}

---@class diffs.MergeHunkInfo
---@field index integer
---@field start_line integer
---@field end_line integer
---@field del_lines string[]
---@field add_lines string[]

---@param bufnr integer
---@return diffs.MergeHunkInfo[]
function M.parse_hunks(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local rail_width = rails.width_for_buffer(bufnr)
  local hunks = {}
  local current = nil

  for i, line in ipairs(lines) do
    line = rails.strip(line, rail_width)
    local idx = i - 1
    if line:match('^@@') then
      if current then
        current.end_line = idx - 1
        table.insert(hunks, current)
      end
      current = {
        index = #hunks + 1,
        start_line = idx,
        end_line = idx,
        del_lines = {},
        add_lines = {},
      }
    elseif current then
      local prefix = line:sub(1, 1)
      if prefix == '-' then
        table.insert(current.del_lines, line:sub(2))
      elseif prefix == '+' then
        table.insert(current.add_lines, line:sub(2))
      elseif prefix ~= ' ' and prefix ~= '\\' then
        current.end_line = idx - 1
        table.insert(hunks, current)
        current = nil
      end
      if current then
        current.end_line = idx
      end
    end
  end

  if current then
    table.insert(hunks, current)
  end

  return hunks
end

---@param bufnr integer
---@return diffs.MergeHunkInfo?
function M.find_hunk_at_cursor(bufnr)
  local hunks = M.parse_hunks(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

  for _, hunk in ipairs(hunks) do
    if cursor_line >= hunk.start_line and cursor_line <= hunk.end_line then
      return hunk
    end
  end

  return nil
end

---@param hunk diffs.MergeHunkInfo
---@param working_bufnr integer
---@return diffs.ConflictRegion?
function M.match_hunk_to_conflict(hunk, working_bufnr)
  local working_lines = vim.api.nvim_buf_get_lines(working_bufnr, 0, -1, false)
  local regions = conflict.parse(working_lines)

  for _, region in ipairs(regions) do
    local ours_lines = {}
    for line = region.ours_start + 1, region.ours_end do
      table.insert(ours_lines, working_lines[line])
    end

    if #ours_lines == #hunk.del_lines then
      local match = true
      for j = 1, #ours_lines do
        if ours_lines[j] ~= hunk.del_lines[j] then
          match = false
          break
        end
      end
      if match then
        return region
      end
    end
  end

  return nil
end

---@param diff_bufnr integer
---@return integer?
function M.get_or_load_working_buf(diff_bufnr)
  local ok, working_path = pcall(vim.api.nvim_buf_get_var, diff_bufnr, 'diffs_working_path')
  if not ok or not working_path then
    return nil
  end

  local existing = vim.fn.bufnr(working_path)
  if existing ~= -1 then
    return existing
  end

  local bufnr = vim.fn.bufadd(working_path)
  vim.fn.bufload(bufnr)
  return bufnr
end

---@param diff_bufnr integer
---@param hunk_index integer
local function mark_resolved(diff_bufnr, hunk_index)
  if not resolved_hunks[diff_bufnr] then
    resolved_hunks[diff_bufnr] = {}
  end
  resolved_hunks[diff_bufnr][hunk_index] = true
end

---@param diff_bufnr integer
---@param hunk_index integer
---@return boolean
function M.is_resolved(diff_bufnr, hunk_index)
  return resolved_hunks[diff_bufnr] and resolved_hunks[diff_bufnr][hunk_index] or false
end

---@param diff_bufnr integer
---@param side 'ours'|'theirs'|'both'|'none'
local function resolve(diff_bufnr, side)
  local hunk = M.find_hunk_at_cursor(diff_bufnr)
  if not hunk then
    return
  end
  if M.is_resolved(diff_bufnr, hunk.index) then
    notify('hunk already resolved', vim.log.levels.INFO)
    return
  end
  local working_bufnr = M.get_or_load_working_buf(diff_bufnr)
  if not working_bufnr then
    return
  end
  local region = M.match_hunk_to_conflict(hunk, working_bufnr)
  if not region then
    notify('hunk does not correspond to a conflict region', vim.log.levels.INFO)
    return
  end
  conflict.replace_region(
    working_bufnr,
    region,
    conflict.replacement_lines(working_bufnr, region, side)
  )
  conflict.refresh(working_bufnr)
  mark_resolved(diff_bufnr, hunk.index)
end

---@param bufnr integer
function M.resolve_ours(bufnr)
  resolve(bufnr, 'ours')
end

---@param bufnr integer
function M.resolve_theirs(bufnr)
  resolve(bufnr, 'theirs')
end

---@param bufnr integer
function M.resolve_both(bufnr)
  resolve(bufnr, 'both')
end

---@param bufnr integer
function M.resolve_none(bufnr)
  resolve(bufnr, 'none')
end

---@param bufnr integer
---@param forward boolean
local function goto_hunk(bufnr, forward)
  local hunks = M.parse_hunks(bufnr)
  if #hunks == 0 then
    return
  end

  local working_bufnr = M.get_or_load_working_buf(bufnr)
  if not working_bufnr then
    return
  end

  local candidates = {}
  for _, hunk in ipairs(hunks) do
    if not M.is_resolved(bufnr, hunk.index) and M.match_hunk_to_conflict(hunk, working_bufnr) then
      table.insert(candidates, hunk)
    end
  end

  if #candidates == 0 then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

  if forward then
    for _, hunk in ipairs(candidates) do
      if hunk.start_line > cursor_line then
        vim.api.nvim_win_set_cursor(0, { hunk.start_line + 1, 0 })
        return
      end
    end
    notify('wrapped to first hunk', vim.log.levels.INFO)
    vim.api.nvim_win_set_cursor(0, { candidates[1].start_line + 1, 0 })
  else
    for i = #candidates, 1, -1 do
      if candidates[i].start_line < cursor_line then
        vim.api.nvim_win_set_cursor(0, { candidates[i].start_line + 1, 0 })
        return
      end
    end
    notify('wrapped to last hunk', vim.log.levels.INFO)
    vim.api.nvim_win_set_cursor(0, { candidates[#candidates].start_line + 1, 0 })
  end
end

---@param bufnr integer
function M.goto_next(bufnr)
  goto_hunk(bufnr, true)
end

---@param bufnr integer
function M.goto_prev(bufnr)
  goto_hunk(bufnr, false)
end

---@param bufnr integer
function M.attach(bufnr)
  resolved_hunks[bufnr] = nil

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      resolved_hunks[bufnr] = nil
    end,
  })
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffsMergeReady', data = { bufnr = bufnr } })
end

return M
