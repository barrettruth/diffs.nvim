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

local ns = vim.api.nvim_create_namespace('diffs-conflict')

---@type table<integer, true>
local attached_buffers = {}

---@type table<integer, boolean>
local diagnostics_suppressed = {}

local PRIORITY_LINE_BG = 200

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

---@param bufnr integer
---@param regions diffs.ConflictRegion[]
---@param config diffs.ConflictConfig
local function apply_highlights(bufnr, regions, config)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  for _, region in ipairs(regions) do
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, region.marker_ours, 0, {
      end_row = region.marker_ours + 1,
      hl_group = 'DiffsConflictMarker',
      hl_eol = true,
      priority = PRIORITY_LINE_BG,
    })

    if config.show_virtual_text then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, region.marker_ours, 0, {
        virt_text = { { ' (current)', 'DiffsConflictMarker' } },
        virt_text_pos = 'eol',
      })
    end

    for line = region.ours_start, region.ours_end - 1 do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
        end_row = line + 1,
        hl_group = 'DiffsConflictOurs',
        hl_eol = true,
        priority = PRIORITY_LINE_BG,
      })
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
        number_hl_group = 'DiffsConflictOursNr',
        priority = PRIORITY_LINE_BG,
      })
    end

    if region.marker_base then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, region.marker_base, 0, {
        end_row = region.marker_base + 1,
        hl_group = 'DiffsConflictMarker',
        hl_eol = true,
        priority = PRIORITY_LINE_BG,
      })

      for line = region.base_start, region.base_end - 1 do
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
          end_row = line + 1,
          hl_group = 'DiffsConflictBase',
          hl_eol = true,
          priority = PRIORITY_LINE_BG,
        })
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
          number_hl_group = 'DiffsConflictBaseNr',
          priority = PRIORITY_LINE_BG,
        })
      end
    end

    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, region.marker_sep, 0, {
      end_row = region.marker_sep + 1,
      hl_group = 'DiffsConflictMarker',
      hl_eol = true,
      priority = PRIORITY_LINE_BG,
    })

    for line = region.theirs_start, region.theirs_end - 1 do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
        end_row = line + 1,
        hl_group = 'DiffsConflictTheirs',
        hl_eol = true,
        priority = PRIORITY_LINE_BG,
      })
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, line, 0, {
        number_hl_group = 'DiffsConflictTheirsNr',
        priority = PRIORITY_LINE_BG,
      })
    end

    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, region.marker_theirs, 0, {
      end_row = region.marker_theirs + 1,
      hl_group = 'DiffsConflictMarker',
      hl_eol = true,
      priority = PRIORITY_LINE_BG,
    })

    if config.show_virtual_text then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, region.marker_theirs, 0, {
        virt_text = { { ' (incoming)', 'DiffsConflictMarker' } },
        virt_text_pos = 'eol',
      })
    end
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
local function replace_region(bufnr, region, replacement)
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
local function refresh(bufnr, config)
  local regions = parse_buffer(bufnr)
  if #regions == 0 then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    if diagnostics_suppressed[bufnr] then
      pcall(vim.diagnostic.reset, nil, bufnr)
      pcall(vim.diagnostic.enable, true, { bufnr = bufnr })
      diagnostics_suppressed[bufnr] = nil
    end
    vim.api.nvim_exec_autocmds('User', { pattern = 'DiffsConflictResolved' })
    return
  end
  apply_highlights(bufnr, regions, config)
  if config.disable_diagnostics and not diagnostics_suppressed[bufnr] then
    pcall(vim.diagnostic.enable, false, { bufnr = bufnr })
    diagnostics_suppressed[bufnr] = true
  end
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_ours(bufnr, config)
  if not vim.api.nvim_get_option_value('modifiable', { buf = bufnr }) then
    vim.notify('[diffs.nvim]: buffer is not modifiable', vim.log.levels.WARN)
    return
  end
  local regions = parse_buffer(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local region = find_conflict_at_cursor(cursor[1] - 1, regions)
  if not region then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, region.ours_start, region.ours_end, false)
  replace_region(bufnr, region, lines)
  refresh(bufnr, config)
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_theirs(bufnr, config)
  if not vim.api.nvim_get_option_value('modifiable', { buf = bufnr }) then
    vim.notify('[diffs.nvim]: buffer is not modifiable', vim.log.levels.WARN)
    return
  end
  local regions = parse_buffer(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local region = find_conflict_at_cursor(cursor[1] - 1, regions)
  if not region then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, region.theirs_start, region.theirs_end, false)
  replace_region(bufnr, region, lines)
  refresh(bufnr, config)
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_both(bufnr, config)
  if not vim.api.nvim_get_option_value('modifiable', { buf = bufnr }) then
    vim.notify('[diffs.nvim]: buffer is not modifiable', vim.log.levels.WARN)
    return
  end
  local regions = parse_buffer(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local region = find_conflict_at_cursor(cursor[1] - 1, regions)
  if not region then
    return
  end
  local ours = vim.api.nvim_buf_get_lines(bufnr, region.ours_start, region.ours_end, false)
  local theirs = vim.api.nvim_buf_get_lines(bufnr, region.theirs_start, region.theirs_end, false)
  local combined = {}
  for _, l in ipairs(ours) do
    table.insert(combined, l)
  end
  for _, l in ipairs(theirs) do
    table.insert(combined, l)
  end
  replace_region(bufnr, region, combined)
  refresh(bufnr, config)
end

---@param bufnr integer
---@param config diffs.ConflictConfig
function M.resolve_none(bufnr, config)
  if not vim.api.nvim_get_option_value('modifiable', { buf = bufnr }) then
    vim.notify('[diffs.nvim]: buffer is not modifiable', vim.log.levels.WARN)
    return
  end
  local regions = parse_buffer(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local region = find_conflict_at_cursor(cursor[1] - 1, regions)
  if not region then
    return
  end
  replace_region(bufnr, region, {})
  refresh(bufnr, config)
end

---@param bufnr integer
function M.goto_next(bufnr)
  local regions = parse_buffer(bufnr)
  if #regions == 0 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1] - 1
  for _, region in ipairs(regions) do
    if region.marker_ours > cursor_line then
      vim.api.nvim_win_set_cursor(0, { region.marker_ours + 1, 0 })
      return
    end
  end
  vim.api.nvim_win_set_cursor(0, { regions[1].marker_ours + 1, 0 })
end

---@param bufnr integer
function M.goto_prev(bufnr)
  local regions = parse_buffer(bufnr)
  if #regions == 0 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1] - 1
  for i = #regions, 1, -1 do
    if regions[i].marker_ours < cursor_line then
      vim.api.nvim_win_set_cursor(0, { regions[i].marker_ours + 1, 0 })
      return
    end
  end
  vim.api.nvim_win_set_cursor(0, { regions[#regions].marker_ours + 1, 0 })
end

---@param bufnr integer
---@param config diffs.ConflictConfig
local function setup_keymaps(bufnr, config)
  local km = config.keymaps

  local maps = {
    { km.ours, '<Plug>(diffs-conflict-ours)' },
    { km.theirs, '<Plug>(diffs-conflict-theirs)' },
    { km.both, '<Plug>(diffs-conflict-both)' },
    { km.none, '<Plug>(diffs-conflict-none)' },
    { km.next, '<Plug>(diffs-conflict-next)' },
    { km.prev, '<Plug>(diffs-conflict-prev)' },
  }

  for _, map in ipairs(maps) do
    if map[1] then
      vim.keymap.set('n', map[1], map[2], { buffer = bufnr })
    end
  end
end

---@param bufnr integer
function M.detach(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
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
      refresh(bufnr, config)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
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
