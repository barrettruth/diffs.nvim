---@class diffs.ConflictRegion
---@field marker_open integer?
---@field marker_ours integer
---@field ours_start integer
---@field ours_end integer
---@field marker_base integer?
---@field base_start integer?
---@field base_end integer?
---@field marker_sep integer
---@field theirs_start integer
---@field theirs_end integer
---@field marker_theirs integer

local M = {}

local notify = require('diffs.log').notify

local ns = vim.api.nvim_create_namespace('diffs-conflict')
local CONFLICT_PRIORITY = 200

---@type table<integer, true>
local attached_buffers = {}


---@param event string
---@param bufnr integer
local function emit(event, bufnr)
  vim.api.nvim_exec_autocmds('User', { pattern = event, data = { bufnr = bufnr } })
end

---@param line string
---@param char string
---@return boolean
local function is_marker(line, char)
  return line:sub(1, 7) == string.rep(char, 7)
end

---@param lines string[]
---@return diffs.ConflictRegion[]
function M.parse(lines)
  local regions = {}
  local state = 'idle'
  ---@type table?
  local current = nil

  for i, line in ipairs(lines) do
    local idx = i - 1

    if state == 'idle' then
      if is_marker(line, '<') then
        local following = lines[i + 1]
        if following and is_marker(following, '+') then
          current = { marker_open = idx }
          state = 'in_snapshot_open'
        else
          current = { marker_ours = idx, ours_start = idx + 1 }
          state = 'in_ours'
        end
      end
    elseif state == 'in_ours' then
      if line:match('^|||||||') then
        current.ours_end = idx
        current.marker_base = idx
        current.base_start = idx + 1
        state = 'in_base'
      elseif line:match('^=======') then
        current.ours_end = idx
        current.marker_sep = idx
        current.theirs_start = idx + 1
        state = 'in_theirs'
      elseif line:match('^<<<<<<<') then
        current = { marker_ours = idx, ours_start = idx + 1 }
      elseif line:match('^>>>>>>>') then
        current = nil
        state = 'idle'
      end
    elseif state == 'in_base' then
      if line:match('^=======') then
        current.base_end = idx
        current.marker_sep = idx
        current.theirs_start = idx + 1
        state = 'in_theirs'
      elseif line:match('^<<<<<<<') then
        current = { marker_ours = idx, ours_start = idx + 1 }
        state = 'in_ours'
      elseif line:match('^>>>>>>>') then
        current = nil
        state = 'idle'
      end
    elseif state == 'in_theirs' then
      if line:match('^>>>>>>>') then
        current.theirs_end = idx
        current.marker_theirs = idx
        table.insert(regions, current)
        current = nil
        state = 'idle'
      elseif line:match('^<<<<<<<') then
        current = { marker_ours = idx, ours_start = idx + 1 }
        state = 'in_ours'
      end
    elseif state == 'in_snapshot_open' then
      current.marker_ours = idx
      current.ours_start = idx + 1
      state = 'in_snapshot_ours'
    elseif state == 'in_snapshot_ours' then
      if is_marker(line, '-') then
        current.ours_end = idx
        current.marker_base = idx
        current.base_start = idx + 1
        state = 'in_snapshot_base'
      elseif is_marker(line, '%') or is_marker(line, '+') or is_marker(line, '>') then
        current = nil
        state = 'idle'
      end
    elseif state == 'in_snapshot_base' then
      if is_marker(line, '+') then
        current.base_end = idx
        current.marker_sep = idx
        current.theirs_start = idx + 1
        state = 'in_snapshot_theirs'
      elseif is_marker(line, '%') or is_marker(line, '-') or is_marker(line, '>') then
        current = nil
        state = 'idle'
      end
    elseif state == 'in_snapshot_theirs' then
      if is_marker(line, '>') then
        current.theirs_end = idx
        current.marker_theirs = idx
        table.insert(regions, current)
        current = nil
        state = 'idle'
      elseif is_marker(line, '%') or is_marker(line, '+') or is_marker(line, '-') then
        current = nil
        state = 'idle'
      end
    end
  end

  return regions
end

---@param region diffs.ConflictRegion
---@return integer
local function region_start(region)
  return region.marker_open or region.marker_ours
end

---@param bufnr integer
---@return diffs.ConflictRegion[]
local function parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.parse(lines)
end

---@param bufnr integer
---@param row integer
---@param hl_group string
local function mark_line(bufnr, row, hl_group)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
    end_row = row + 1,
    hl_group = hl_group,
    hl_eol = true,
    priority = CONFLICT_PRIORITY,
  })
end

---@param bufnr integer
---@param start_row integer
---@param end_row integer
---@param hl_group string
---@param number_hl_group string
local function mark_section(bufnr, start_row, end_row, hl_group, number_hl_group)
  for row = start_row, end_row - 1 do
    mark_line(bufnr, row, hl_group)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
      number_hl_group = number_hl_group,
      priority = CONFLICT_PRIORITY,
    })
  end
end

---@param bufnr integer
---@param regions diffs.ConflictRegion[]
local function apply_highlights(bufnr, regions)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for _, region in ipairs(regions) do
    if region.marker_open then
      mark_line(bufnr, region.marker_open, 'DiffsConflictMarker')
    end
    mark_line(bufnr, region.marker_ours, 'DiffsConflictMarker')
    mark_section(
      bufnr,
      region.ours_start,
      region.ours_end,
      'DiffsConflictOurs',
      'DiffsConflictOursNr'
    )

    if region.marker_base then
      mark_line(bufnr, region.marker_base, 'DiffsConflictMarker')
      mark_section(
        bufnr,
        region.base_start,
        region.base_end,
        'DiffsConflictBase',
        'DiffsConflictBaseNr'
      )
    end

    mark_line(bufnr, region.marker_sep, 'DiffsConflictMarker')
    mark_section(
      bufnr,
      region.theirs_start,
      region.theirs_end,
      'DiffsConflictTheirs',
      'DiffsConflictTheirsNr'
    )
    mark_line(bufnr, region.marker_theirs, 'DiffsConflictMarker')
  end
end

---@param cursor_line integer
---@param regions diffs.ConflictRegion[]
---@return diffs.ConflictRegion?
local function find_conflict_at_cursor(cursor_line, regions)
  for _, region in ipairs(regions) do
    if cursor_line >= region_start(region) and cursor_line <= region.marker_theirs then
      return region
    end
  end
  return nil
end

---@param bufnr integer
---@param region diffs.ConflictRegion
---@param replacement string[]
function M.replace_region(bufnr, region, replacement)
  vim.api.nvim_buf_set_lines(
    bufnr,
    region_start(region),
    region.marker_theirs + 1,
    false,
    replacement
  )
end

---@param bufnr integer
function M.refresh(bufnr)
  local had_conflicts = #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { limit = 1 }) > 0
  local regions = parse_buffer(bufnr)
  if #regions == 0 then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    if had_conflicts then
      emit('DiffsConflictResolved', bufnr)
    end
    return
  end
  apply_highlights(bufnr, regions)
  if not had_conflicts then
    emit('DiffsConflictDetected', bufnr)
  end
end

---@param bufnr integer
---@param region diffs.ConflictRegion
---@param side 'ours'|'theirs'|'both'|'none'
---@return string[]
function M.replacement_lines(bufnr, region, side)
  if side == 'none' then
    return {}
  end
  if side == 'theirs' then
    return vim.api.nvim_buf_get_lines(bufnr, region.theirs_start, region.theirs_end, false)
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, region.ours_start, region.ours_end, false)
  if side == 'both' then
    vim.list_extend(
      lines,
      vim.api.nvim_buf_get_lines(bufnr, region.theirs_start, region.theirs_end, false)
    )
  end
  return lines
end

---@param bufnr integer
---@param side 'ours'|'theirs'|'both'|'none'
local function resolve(bufnr, side)
  if not vim.api.nvim_get_option_value('modifiable', { buf = bufnr }) then
    notify('buffer is not modifiable', vim.log.levels.WARN)
    return
  end
  local regions = parse_buffer(bufnr)
  local region = find_conflict_at_cursor(vim.api.nvim_win_get_cursor(0)[1] - 1, regions)
  if not region then
    return
  end
  M.replace_region(bufnr, region, M.replacement_lines(bufnr, region, side))
  M.refresh(bufnr)
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
local function goto_conflict(bufnr, forward)
  local regions = parse_buffer(bufnr)
  if #regions == 0 then
    return
  end
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  if forward then
    for _, region in ipairs(regions) do
      if region_start(region) > cursor_line then
        vim.api.nvim_win_set_cursor(0, { region_start(region) + 1, 0 })
        return
      end
    end
    notify('wrapped to first conflict', vim.log.levels.INFO)
    vim.api.nvim_win_set_cursor(0, { region_start(regions[1]) + 1, 0 })
  else
    for i = #regions, 1, -1 do
      if region_start(regions[i]) < cursor_line then
        vim.api.nvim_win_set_cursor(0, { region_start(regions[i]) + 1, 0 })
        return
      end
    end
    notify('wrapped to last conflict', vim.log.levels.INFO)
    vim.api.nvim_win_set_cursor(0, { region_start(regions[#regions]) + 1, 0 })
  end
end

---@param bufnr integer
function M.goto_next(bufnr)
  goto_conflict(bufnr, true)
end

---@param bufnr integer
function M.goto_prev(bufnr)
  goto_conflict(bufnr, false)
end

---@param bufnr integer
function M.detach(bufnr)
  local attached = attached_buffers[bufnr]
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  attached_buffers[bufnr] = nil

  if attached then
    emit('DiffsConflictDetached', bufnr)
  end
end

---@param bufnr integer
function M.attach(bufnr)
  if attached_buffers[bufnr] then
    return
  end

  local buftype = vim.api.nvim_get_option_value('buftype', { buf = bufnr })
  if buftype ~= '' then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local regions = M.parse(lines)
  if #regions == 0 then
    return
  end

  attached_buffers[bufnr] = true

  apply_highlights(bufnr, regions)

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = bufnr,
    callback = function()
      if not attached_buffers[bufnr] then
        return true
      end
      M.refresh(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      attached_buffers[bufnr] = nil
    end,
  })
  emit('DiffsConflictDetected', bufnr)
end

---@return integer
function M.get_namespace()
  return ns
end

return M
