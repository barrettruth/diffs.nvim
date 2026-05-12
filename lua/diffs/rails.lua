local M = {}

local hunk_model = require('diffs.hunks')

local bar_slot = '  '
local separator = ' ┃ '
local compact_separator = separator:gsub('%s+$', '')

---@class diffs.RailInfo
---@field width integer
---@field prefix_width integer

---@class diffs.RailRanges
---@field old_start integer
---@field old_end integer
---@field new_start integer
---@field new_end integer

---@param value integer?
---@param width integer
---@return string
local function format_lnum(value, width)
  if not value then
    return string.rep(' ', width)
  end
  return string.format('%' .. width .. 'd', value)
end

---@param line diffs.GdiffHunkLine?
---@return integer?
local function old_lnum(line)
  if line and (line.kind == 'context' or line.kind == 'delete') then
    return line.old_lnum
  end
  return nil
end

---@param line diffs.GdiffHunkLine?
---@return integer?
local function new_lnum(line)
  if line and (line.kind == 'context' or line.kind == 'add') then
    return line.new_lnum
  end
  return nil
end

---@param line diffs.GdiffHunkLine?
---@param text string
---@return boolean
local function is_empty_context_line(line, text)
  return line ~= nil and line.kind == 'context' and text == ' '
end

---@param line string
---@param start_col integer
---@param end_col integer
---@return boolean
local function has_number(line, start_col, end_col)
  return line:sub(start_col + 1, end_col):find('%d') ~= nil
end

---@param line string
---@param prefix_width integer
---@return boolean
local function has_context_rails(line, prefix_width)
  local ranges = M.ranges(prefix_width)
  return ranges ~= nil
    and has_number(line, ranges.old_start, ranges.old_end)
    and has_number(line, ranges.new_start, ranges.new_end)
end

---@param lines string[]
---@return table<integer, diffs.GdiffHunkLine>, integer
local function collect_lines(lines)
  local by_lnum = {}
  local max_lnum = 0

  for _, hunk in ipairs(hunk_model.parse(lines)) do
    for _, line in ipairs(hunk.lines) do
      by_lnum[line.lnum] = line
      max_lnum = math.max(max_lnum, line.old_lnum or 0, line.new_lnum or 0)
    end
  end

  return by_lnum, max_lnum
end

---@param lines string[]
---@return string[], diffs.RailInfo?
function M.annotate(lines)
  local by_lnum, max_lnum = collect_lines(lines)
  if vim.tbl_isempty(by_lnum) then
    return lines, nil
  end

  local width = math.max(1, #tostring(max_lnum))
  local prefix_width = #bar_slot + width + 1 + width + #separator
  local annotated = {}

  for lnum, text in ipairs(lines) do
    local line = by_lnum[lnum]
    local line_separator = is_empty_context_line(line, text) and compact_separator or separator
    local display_text = is_empty_context_line(line, text) and '' or text
    annotated[lnum] = bar_slot
      .. format_lnum(old_lnum(line), width)
      .. ' '
      .. format_lnum(new_lnum(line), width)
      .. line_separator
      .. display_text
  end

  return annotated, {
    width = width,
    prefix_width = prefix_width,
  }
end

---@param line string
---@param prefix_width integer?
---@return string
function M.strip(line, prefix_width)
  if type(prefix_width) ~= 'number' or prefix_width <= 0 then
    return line
  end
  local stripped = line:sub(prefix_width + 1)
  if stripped == '' and has_context_rails(line, prefix_width) then
    return ' '
  end
  return stripped
end

---@param lines string[]
---@param prefix_width integer?
---@return string[]
function M.strip_lines(lines, prefix_width)
  if type(prefix_width) ~= 'number' or prefix_width <= 0 then
    return lines
  end

  local stripped = {}
  for i, line in ipairs(lines) do
    stripped[i] = M.strip(line, prefix_width)
  end
  return stripped
end

---@param prefix_width integer?
---@return diffs.RailRanges?
function M.ranges(prefix_width)
  if type(prefix_width) ~= 'number' or prefix_width <= 0 then
    return nil
  end

  local width = (prefix_width - #bar_slot - 1 - #separator) / 2
  if width < 1 or width % 1 ~= 0 then
    return nil
  end

  local old_start = #bar_slot
  local old_end = old_start + width
  local new_start = old_end + 1
  local new_end = new_start + width

  return {
    old_start = old_start,
    old_end = old_end,
    new_start = new_start,
    new_end = new_end,
  }
end

---@param bufnr integer
---@return integer
function M.width_for_buffer(bufnr)
  local ok, width = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_rail_width')
  if ok and type(width) == 'number' and width > 0 then
    return width
  end
  return 0
end

M._test = {
  format_lnum = format_lnum,
}

return M
