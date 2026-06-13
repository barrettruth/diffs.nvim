---@class diffs.ConflictRegion
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

local keymaps = require('diffs.keymaps')
local notify = require('diffs.log').notify

local ns = vim.api.nvim_create_namespace('diffs-conflict')
local CONFLICT_PRIORITY = 200

---@type table<integer, true>
local attached_buffers = {}

---@type table<integer, boolean>
local diagnostics_suppressed = {}

---@type table<integer, table<string, diffs.BufferKeymap>>
local buffer_keymaps = {}

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
      if line:match('^<<<<<<<') then
        current = { marker_ours = idx, ours_start = idx + 1 }
        state = 'in_ours'
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
    end
  end

  return regions
end

---@param bufnr integer
---@return diffs.ConflictRegion[]
local function parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return M.parse(lines)
end

---@type table<'ours'|'base'|'theirs', string>
local default_labels = { ours = 'current', base = 'base', theirs = 'incoming' }

---@param side 'ours'|'base'|'theirs'
---@param config diffs.ConflictConfig
---@return string?
local function get_virtual_text_label(side, config)
  if config.format_virtual_text then
    ---@type string|false
    local keymap = false
    if side == 'ours' then
      keymap = keymaps.get_conflict_keymap(config, 'ours')
    elseif side == 'theirs' then
      keymap = keymaps.get_conflict_keymap(config, 'theirs')
    end
    return config.format_virtual_text(side, keymap)
  end
  return default_labels[side]
end

---@param bufnr integer
---@param row integer
---@param side 'ours'|'base'|'theirs'
---@param config diffs.ConflictConfig
local function apply_marker_label(bufnr, row, side, config)
  if not config.show_virtual_text then
    return
  end
  local label = get_virtual_text_label(side, config)
  if not label then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
    virt_text = { { ' (' .. label .. ')', 'DiffsConflictMarker' } },
    virt_text_pos = 'eol',
  })
end

local setup_keymaps

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
---@param region diffs.ConflictRegion
---@param config diffs.ConflictConfig
local function apply_action_hints(bufnr, region, config)
  if not config.show_actions then
    return
  end
  local parts = {}
  local actions = {
    { 'Current', keymaps.get_conflict_keymap(config, 'ours') },
    { 'Incoming', keymaps.get_conflict_keymap(config, 'theirs') },
    { 'Both', keymaps.get_conflict_keymap(config, 'both') },
    { 'None', keymaps.get_conflict_keymap(config, 'none') },
  }
  for _, action in ipairs(actions) do
    if action[2] then
      if #parts > 0 then
        table.insert(parts, { ' \226\148\130 ', 'DiffsConflictActions' })
      end
      table.insert(parts, { ('%s (%s)'):format(action[1], action[2]), 'DiffsConflictActions' })
    end
  end
  if #parts > 0 then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, region.marker_ours, 0, {
      virt_lines = { parts },
      virt_lines_above = true,
    })
  end
end

---@param bufnr integer
---@param regions diffs.ConflictRegion[]
---@param config diffs.ConflictConfig
local function apply_highlights(bufnr, regions, config)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for _, region in ipairs(regions) do
    mark_line(bufnr, region.marker_ours, 'DiffsConflictMarker')
    apply_marker_label(bufnr, region.marker_ours, 'ours', config)
    apply_action_hints(bufnr, region, config)
    mark_section(
      bufnr,
      region.ours_start,
      region.ours_end,
      'DiffsConflictOurs',
      'DiffsConflictOursNr'
    )

    if region.marker_base then
      mark_line(bufnr, region.marker_base, 'DiffsConflictMarker')
      apply_marker_label(bufnr, region.marker_base, 'base', config)
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
    apply_marker_label(bufnr, region.marker_theirs, 'theirs', config)
  end
end

---@param cursor_line integer
---@param regions diffs.ConflictRegion[]
---@return diffs.ConflictRegion?
local function find_conflict_at_cursor(cursor_line, regions)
  for _, region in ipairs(regions) do
    if cursor_line >= region.marker_ours and cursor_line <= region.marker_theirs then
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
    region.marker_ours,
    region.marker_theirs + 1,
    false,
    replacement
  )
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.refresh(bufnr, config)
  local regions = parse_buffer(bufnr)
  if #regions == 0 then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    keymaps.clear_buffer_keymaps(buffer_keymaps, bufnr)
    if diagnostics_suppressed[bufnr] then
      pcall(vim.diagnostic.reset, nil, bufnr)
      pcall(vim.diagnostic.enable, true, { bufnr = bufnr })
      diagnostics_suppressed[bufnr] = nil
    end
    vim.api.nvim_exec_autocmds('User', { pattern = 'DiffsConflictResolved' })
    return
  end
  apply_highlights(bufnr, regions, config)
  if not buffer_keymaps[bufnr] then
    setup_keymaps(bufnr, config)
  end
  if config.disable_diagnostics and not diagnostics_suppressed[bufnr] then
    pcall(vim.diagnostic.enable, false, { bufnr = bufnr })
    diagnostics_suppressed[bufnr] = true
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
---@param config diffs.ConflictConfig
---@param side 'ours'|'theirs'|'both'|'none'
local function resolve(bufnr, config, side)
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
  M.refresh(bufnr, config)
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_ours(bufnr, config)
  resolve(bufnr, config, 'ours')
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_theirs(bufnr, config)
  resolve(bufnr, config, 'theirs')
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_both(bufnr, config)
  resolve(bufnr, config, 'both')
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_none(bufnr, config)
  resolve(bufnr, config, 'none')
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
      if region.marker_ours > cursor_line then
        vim.api.nvim_win_set_cursor(0, { region.marker_ours + 1, 0 })
        return
      end
    end
    notify('wrapped to first conflict', vim.log.levels.INFO)
    vim.api.nvim_win_set_cursor(0, { regions[1].marker_ours + 1, 0 })
  else
    for i = #regions, 1, -1 do
      if regions[i].marker_ours < cursor_line then
        vim.api.nvim_win_set_cursor(0, { regions[i].marker_ours + 1, 0 })
        return
      end
    end
    notify('wrapped to last conflict', vim.log.levels.INFO)
    vim.api.nvim_win_set_cursor(0, { regions[#regions].marker_ours + 1, 0 })
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
---@param config diffs.ConflictConfig
setup_keymaps = function(bufnr, config)
  local km = config.keymaps
  if km == false then
    keymaps.clear_buffer_keymaps(buffer_keymaps, bufnr)
    return
  end

  keymaps.set_buffer_keymaps(buffer_keymaps, bufnr, {
    { km.ours, '<Plug>(diffs-conflict-ours)' },
    { km.theirs, '<Plug>(diffs-conflict-theirs)' },
    { km.both, '<Plug>(diffs-conflict-both)' },
    { km.none, '<Plug>(diffs-conflict-none)' },
    { km.next, '<Plug>(diffs-conflict-next)' },
    { km.prev, '<Plug>(diffs-conflict-prev)' },
  })
end

---@param bufnr integer
function M.detach(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  keymaps.clear_buffer_keymaps(buffer_keymaps, bufnr)
  attached_buffers[bufnr] = nil

  if diagnostics_suppressed[bufnr] then
    pcall(vim.diagnostic.reset, nil, bufnr)
    pcall(vim.diagnostic.enable, true, { bufnr = bufnr })
    diagnostics_suppressed[bufnr] = nil
  end
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.attach(bufnr, config)
  if attached_buffers[bufnr] then
    return
  end

  local buftype = vim.api.nvim_get_option_value('buftype', { buf = bufnr })
  if buftype ~= '' then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local has_marker = false
  for _, line in ipairs(lines) do
    if line:match('^<<<<<<<') then
      has_marker = true
      break
    end
  end
  if not has_marker then
    return
  end

  attached_buffers[bufnr] = true

  local regions = M.parse(lines)
  apply_highlights(bufnr, regions, config)
  setup_keymaps(bufnr, config)

  if config.disable_diagnostics then
    pcall(vim.diagnostic.enable, false, { bufnr = bufnr })
    diagnostics_suppressed[bufnr] = true
  end

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = bufnr,
    callback = function()
      if not attached_buffers[bufnr] then
        return true
      end
      M.refresh(bufnr, config)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      keymaps.clear_buffer_keymaps(buffer_keymaps, bufnr)
      attached_buffers[bufnr] = nil
      diagnostics_suppressed[bufnr] = nil
    end,
  })
end

---@return integer
function M.get_namespace()
  return ns
end

return M
