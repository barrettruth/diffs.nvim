local M = {}

local enabled = false
local entries = {}
local attach_counts = {}

local hrtime = vim.uv.hrtime

---@param val boolean
function M.set_enabled(val)
  enabled = val
end

---@return boolean
function M.is_enabled()
  return enabled
end

---@return integer
function M.start()
  return hrtime()
end

---@param event string
---@param start_ns integer
---@param fields? table
function M.record(event, start_ns, fields)
  if not enabled then
    return
  end
  local end_ns = hrtime()
  local entry = vim.tbl_extend('force', fields or {}, {
    event = event,
    duration_us = math.floor((end_ns - start_ns) / 1000),
    timestamp = start_ns,
  })
  table.insert(entries, entry)
end

---@param bufnr integer
---@param source string
function M.record_attach(bufnr, source)
  if not enabled then
    return
  end
  if not attach_counts[bufnr] then
    attach_counts[bufnr] = {}
  end
  attach_counts[bufnr][source] = (attach_counts[bufnr][source] or 0) + 1
end

function M.flush()
  if not enabled or #entries == 0 then
    return
  end
  local path = vim.fn.stdpath('state') .. '/diffs_profile.jsonl'
  local file = io.open(path, 'a')
  if not file then
    return
  end
  for _, entry in ipairs(entries) do
    file:write(vim.json.encode(entry) .. '\n')
  end
  file:close()
end

---@param us integer
---@return string
local function format_duration(us)
  if us >= 1000000 then
    return string.format('%.2fs', us / 1000000)
  elseif us >= 1000 then
    return string.format('%.1fms', us / 1000)
  end
  return string.format('%dus', us)
end

function M.dump()
  if #entries == 0 and vim.tbl_isempty(attach_counts) then
    vim.notify('[diffs.nvim profile] no data recorded', vim.log.levels.INFO)
    return
  end

  local lines = { '[diffs.nvim profile]', '' }

  local phase_totals = {}
  local phase_counts = {}
  local slowest_hunks = {}
  local total_buffer_us = 0
  local buffer_calls = 0

  for _, e in ipairs(entries) do
    local ev = e.event
    phase_totals[ev] = (phase_totals[ev] or 0) + e.duration_us
    phase_counts[ev] = (phase_counts[ev] or 0) + 1

    if ev == 'highlight_buffer' then
      total_buffer_us = total_buffer_us + e.duration_us
      buffer_calls = buffer_calls + 1
    end

    if ev == 'highlight_hunk' then
      table.insert(slowest_hunks, e)
    end
  end

  table.insert(
    lines,
    string.format(
      'highlight_buffer: %d calls, %s total',
      buffer_calls,
      format_duration(total_buffer_us)
    )
  )
  table.insert(lines, '')

  table.insert(lines, 'Phase breakdown:')
  local phase_order = {
    'parse_buffer',
    'highlight_hunk',
    'highlight_treesitter',
    'highlight_vim_syntax',
    'compute_intra_hunks',
  }
  for _, phase in ipairs(phase_order) do
    if phase_totals[phase] then
      table.insert(
        lines,
        string.format(
          '  %-25s %4d calls  %s',
          phase,
          phase_counts[phase],
          format_duration(phase_totals[phase])
        )
      )
    end
  end
  table.insert(lines, '')

  table.sort(slowest_hunks, function(a, b)
    return a.duration_us > b.duration_us
  end)
  local top_n = math.min(10, #slowest_hunks)
  if top_n > 0 then
    table.insert(lines, string.format('Top %d slowest hunks:', top_n))
    for i = 1, top_n do
      local h = slowest_hunks[i]
      table.insert(
        lines,
        string.format(
          '  %s  %s:%d (%d lines, %s, %d extmarks)',
          format_duration(h.duration_us),
          h.filename or '?',
          h.hunk_start_line or 0,
          h.hunk_lines or 0,
          h.codepath or '?',
          h.extmark_count or 0
        )
      )
    end
    table.insert(lines, '')
  end

  if not vim.tbl_isempty(attach_counts) then
    table.insert(lines, 'highlight_buffer trigger counts:')
    for bufnr, sources in pairs(attach_counts) do
      local buf_name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr)
        or '(invalid)'
      table.insert(lines, string.format('  buf %d (%s):', bufnr, buf_name))
      for source, count in pairs(sources) do
        table.insert(lines, string.format('    %-20s %d', source, count))
      end
    end
    table.insert(lines, '')
  end

  local path = vim.fn.stdpath('state') .. '/diffs_profile.jsonl'
  table.insert(lines, string.format('JSONL log: %s', path))

  M.flush()
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
end

function M.reset()
  entries = {}
  attach_counts = {}
  local path = vim.fn.stdpath('state') .. '/diffs_profile.jsonl'
  local file = io.open(path, 'w')
  if file then
    file:close()
  end
  vim.notify('[diffs.nvim profile] reset', vim.log.levels.INFO)
end

return M
