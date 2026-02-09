local M = {}

local conflict = require('diffs.conflict')

local ns = vim.api.nvim_create_namespace('diffs-merge')

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
  local hunks = {}
  local current = nil

  for i, line in ipairs(lines) do
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
---@param hunk diffs.MergeHunkInfo
local function add_resolved_virtual_text(diff_bufnr, hunk)
  pcall(vim.api.nvim_buf_set_extmark, diff_bufnr, ns, hunk.start_line, 0, {
    virt_text = { { ' (resolved)', 'Comment' } },
    virt_text_pos = 'eol',
  })
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_ours(bufnr, config)
  local hunk = M.find_hunk_at_cursor(bufnr)
  if not hunk then
    return
  end
  if M.is_resolved(bufnr, hunk.index) then
    vim.notify('[diffs.nvim]: hunk already resolved', vim.log.levels.INFO)
    return
  end
  local working_bufnr = M.get_or_load_working_buf(bufnr)
  if not working_bufnr then
    return
  end
  local region = M.match_hunk_to_conflict(hunk, working_bufnr)
  if not region then
    vim.notify('[diffs.nvim]: hunk does not correspond to a conflict region', vim.log.levels.INFO)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(working_bufnr, region.ours_start, region.ours_end, false)
  conflict.replace_region(working_bufnr, region, lines)
  conflict.refresh(working_bufnr, config)
  mark_resolved(bufnr, hunk.index)
  add_resolved_virtual_text(bufnr, hunk)
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_theirs(bufnr, config)
  local hunk = M.find_hunk_at_cursor(bufnr)
  if not hunk then
    return
  end
  if M.is_resolved(bufnr, hunk.index) then
    vim.notify('[diffs.nvim]: hunk already resolved', vim.log.levels.INFO)
    return
  end
  local working_bufnr = M.get_or_load_working_buf(bufnr)
  if not working_bufnr then
    return
  end
  local region = M.match_hunk_to_conflict(hunk, working_bufnr)
  if not region then
    vim.notify('[diffs.nvim]: hunk does not correspond to a conflict region', vim.log.levels.INFO)
    return
  end
  local lines =
    vim.api.nvim_buf_get_lines(working_bufnr, region.theirs_start, region.theirs_end, false)
  conflict.replace_region(working_bufnr, region, lines)
  conflict.refresh(working_bufnr, config)
  mark_resolved(bufnr, hunk.index)
  add_resolved_virtual_text(bufnr, hunk)
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_both(bufnr, config)
  local hunk = M.find_hunk_at_cursor(bufnr)
  if not hunk then
    return
  end
  if M.is_resolved(bufnr, hunk.index) then
    vim.notify('[diffs.nvim]: hunk already resolved', vim.log.levels.INFO)
    return
  end
  local working_bufnr = M.get_or_load_working_buf(bufnr)
  if not working_bufnr then
    return
  end
  local region = M.match_hunk_to_conflict(hunk, working_bufnr)
  if not region then
    vim.notify('[diffs.nvim]: hunk does not correspond to a conflict region', vim.log.levels.INFO)
    return
  end
  local ours = vim.api.nvim_buf_get_lines(working_bufnr, region.ours_start, region.ours_end, false)
  local theirs =
    vim.api.nvim_buf_get_lines(working_bufnr, region.theirs_start, region.theirs_end, false)
  local combined = {}
  for _, l in ipairs(ours) do
    table.insert(combined, l)
  end
  for _, l in ipairs(theirs) do
    table.insert(combined, l)
  end
  conflict.replace_region(working_bufnr, region, combined)
  conflict.refresh(working_bufnr, config)
  mark_resolved(bufnr, hunk.index)
  add_resolved_virtual_text(bufnr, hunk)
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_none(bufnr, config)
  local hunk = M.find_hunk_at_cursor(bufnr)
  if not hunk then
    return
  end
  if M.is_resolved(bufnr, hunk.index) then
    vim.notify('[diffs.nvim]: hunk already resolved', vim.log.levels.INFO)
    return
  end
  local working_bufnr = M.get_or_load_working_buf(bufnr)
  if not working_bufnr then
    return
  end
  local region = M.match_hunk_to_conflict(hunk, working_bufnr)
  if not region then
    vim.notify('[diffs.nvim]: hunk does not correspond to a conflict region', vim.log.levels.INFO)
    return
  end
  conflict.replace_region(working_bufnr, region, {})
  conflict.refresh(working_bufnr, config)
  mark_resolved(bufnr, hunk.index)
  add_resolved_virtual_text(bufnr, hunk)
end

---@param bufnr integer
function M.goto_next(bufnr)
  local hunks = M.parse_hunks(bufnr)
  if #hunks == 0 then
    return
  end

  local working_bufnr = M.get_or_load_working_buf(bufnr)
  if not working_bufnr then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

  local candidates = {}
  for _, hunk in ipairs(hunks) do
    if not M.is_resolved(bufnr, hunk.index) then
      if M.match_hunk_to_conflict(hunk, working_bufnr) then
        table.insert(candidates, hunk)
      end
    end
  end

  if #candidates == 0 then
    return
  end

  for _, hunk in ipairs(candidates) do
    if hunk.start_line > cursor_line then
      vim.api.nvim_win_set_cursor(0, { hunk.start_line + 1, 0 })
      return
    end
  end

  vim.notify('[diffs.nvim]: wrapped to first hunk', vim.log.levels.INFO)
  vim.api.nvim_win_set_cursor(0, { candidates[1].start_line + 1, 0 })
end

---@param bufnr integer
function M.goto_prev(bufnr)
  local hunks = M.parse_hunks(bufnr)
  if #hunks == 0 then
    return
  end

  local working_bufnr = M.get_or_load_working_buf(bufnr)
  if not working_bufnr then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1

  local candidates = {}
  for _, hunk in ipairs(hunks) do
    if not M.is_resolved(bufnr, hunk.index) then
      if M.match_hunk_to_conflict(hunk, working_bufnr) then
        table.insert(candidates, hunk)
      end
    end
  end

  if #candidates == 0 then
    return
  end

  for i = #candidates, 1, -1 do
    if candidates[i].start_line < cursor_line then
      vim.api.nvim_win_set_cursor(0, { candidates[i].start_line + 1, 0 })
      return
    end
  end

  vim.notify('[diffs.nvim]: wrapped to last hunk', vim.log.levels.INFO)
  vim.api.nvim_win_set_cursor(0, { candidates[#candidates].start_line + 1, 0 })
end

---@param bufnr integer
---@param config diffs.ConflictConfig
local function apply_hunk_hints(bufnr, config)
  if not config.show_virtual_text then
    return
  end

  local hunks = M.parse_hunks(bufnr)
  for _, hunk in ipairs(hunks) do
    if M.is_resolved(bufnr, hunk.index) then
      add_resolved_virtual_text(bufnr, hunk)
    else
      local parts = {}
      local actions = {
        { 'current', config.keymaps.ours },
        { 'incoming', config.keymaps.theirs },
        { 'both', config.keymaps.both },
        { 'none', config.keymaps.none },
      }
      for _, action in ipairs(actions) do
        if action[2] then
          if #parts > 0 then
            table.insert(parts, { ' | ', 'Comment' })
          end
          table.insert(parts, { ('%s: %s'):format(action[2], action[1]), 'Comment' })
        end
      end
      if #parts > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, hunk.start_line, 0, {
          virt_text = parts,
          virt_text_pos = 'eol',
        })
      end
    end
  end
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.setup_keymaps(bufnr, config)
  resolved_hunks[bufnr] = nil
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local km = config.keymaps

  local maps = {
    { km.ours, '<Plug>(diffs-merge-ours)' },
    { km.theirs, '<Plug>(diffs-merge-theirs)' },
    { km.both, '<Plug>(diffs-merge-both)' },
    { km.none, '<Plug>(diffs-merge-none)' },
    { km.next, '<Plug>(diffs-merge-next)' },
    { km.prev, '<Plug>(diffs-merge-prev)' },
  }

  for _, map in ipairs(maps) do
    if map[1] then
      vim.keymap.set('n', map[1], map[2], { buffer = bufnr })
    end
  end

  apply_hunk_hints(bufnr, config)

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      resolved_hunks[bufnr] = nil
    end,
  })
end

---@return integer
function M.get_namespace()
  return ns
end

return M
