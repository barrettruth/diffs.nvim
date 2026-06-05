local M = {}

local hunk_model = require('diffs.hunks')

local default_rail_separator = '│'
local bar_slot = '  '

---@alias diffs.RailStyle "dual"|"single"

---@param glyph string?
---@return string
local function separator_for(glyph)
  return ' ' .. (glyph or default_rail_separator) .. ' '
end

---@class diffs.RailInfo
---@field width integer
---@field prefix_width integer
---@field separator_width integer
---@field style diffs.RailStyle

---@class diffs.RailRanges
---@field old_start integer
---@field old_end integer
---@field new_start integer
---@field new_end integer

---@class diffs.RailNumberRange
---@field start integer
---@field finish integer

---@param style diffs.RailStyle?
---@return diffs.RailStyle
local function normalize_rail_style(style)
  if style == 'single' then
    return 'single'
  end
  return 'dual'
end

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
---@return integer?
local function single_lnum(line)
  if not line then
    return nil
  end
  if line.kind == 'delete' then
    return line.old_lnum
  end
  if line.kind == 'context' or line.kind == 'add' then
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
---@param ranges diffs.RailNumberRange[]?
---@return boolean
local function any_range_has_number(line, ranges)
  for _, range in ipairs(ranges or {}) do
    if has_number(line, range.start, range.finish) then
      return true
    end
  end
  return false
end

---@param line string
---@param prefix_width integer
---@param separator_width? integer
---@return boolean
local function has_rail_number(line, prefix_width, separator_width)
  return any_range_has_number(line, M.number_ranges(prefix_width, separator_width, 'dual'))
    or any_range_has_number(line, M.number_ranges(prefix_width, separator_width, 'single'))
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
---@param opts? { rail_separator?: string, rail_style?: diffs.RailStyle }
---@return string[], diffs.RailInfo?
function M.annotate(lines, opts)
  opts = opts or {}
  local rail_style = normalize_rail_style(opts.rail_style)
  local separator = separator_for(opts.rail_separator)
  local compact_separator = separator:gsub('%s+$', '')

  local by_lnum, max_lnum = collect_lines(lines)
  if vim.tbl_isempty(by_lnum) then
    return lines, nil
  end

  local width = math.max(1, #tostring(max_lnum))
  local prefix_width = rail_style == 'single' and (#bar_slot + width + #separator)
    or (#bar_slot + width + 1 + width + #separator)
  local annotated = {}

  for lnum, text in ipairs(lines) do
    local line = by_lnum[lnum]
    local line_separator = is_empty_context_line(line, text) and compact_separator or separator
    local display_text = is_empty_context_line(line, text) and '' or text
    if rail_style == 'single' then
      annotated[lnum] = bar_slot
        .. format_lnum(single_lnum(line), width)
        .. line_separator
        .. display_text
    else
      annotated[lnum] = bar_slot
        .. format_lnum(old_lnum(line), width)
        .. ' '
        .. format_lnum(new_lnum(line), width)
        .. line_separator
        .. display_text
    end
  end

  return annotated,
    {
      width = width,
      prefix_width = prefix_width,
      separator_width = #separator,
      style = rail_style,
    }
end

---@param line string
---@param prefix_width integer?
---@param separator_width? integer
---@return string
function M.strip(line, prefix_width, separator_width)
  if type(prefix_width) ~= 'number' or prefix_width <= 0 then
    return line
  end
  local stripped = line:sub(prefix_width + 1)
  if stripped == '' and has_rail_number(line, prefix_width, separator_width) then
    return ' '
  end
  return stripped
end

---@param lines string[]
---@param prefix_width integer?
---@param separator_width? integer
---@return string[]
function M.strip_lines(lines, prefix_width, separator_width)
  if type(prefix_width) ~= 'number' or prefix_width <= 0 then
    return lines
  end

  local stripped = {}
  for i, line in ipairs(lines) do
    stripped[i] = M.strip(line, prefix_width, separator_width)
  end
  return stripped
end

---@param prefix_width integer?
---@param separator_width? integer
---@return diffs.RailRanges?
function M.ranges(prefix_width, separator_width)
  if type(prefix_width) ~= 'number' or prefix_width <= 0 then
    return nil
  end
  separator_width = separator_width or #separator_for()

  local width = (prefix_width - #bar_slot - 1 - separator_width) / 2
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

---@param prefix_width integer?
---@param separator_width? integer
---@param rail_style? diffs.RailStyle
---@return diffs.RailNumberRange[]?
function M.number_ranges(prefix_width, separator_width, rail_style)
  if type(prefix_width) ~= 'number' or prefix_width <= 0 then
    return nil
  end
  separator_width = separator_width or #separator_for()

  if normalize_rail_style(rail_style) == 'single' then
    local width = prefix_width - #bar_slot - separator_width
    if width < 1 or width % 1 ~= 0 then
      return nil
    end

    return {
      {
        start = #bar_slot,
        finish = #bar_slot + width,
      },
    }
  end

  local ranges = M.ranges(prefix_width, separator_width)
  if not ranges then
    return nil
  end

  return {
    {
      start = ranges.old_start,
      finish = ranges.old_end,
    },
    {
      start = ranges.new_start,
      finish = ranges.new_end,
    },
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

---@param bufnr integer
---@return integer
function M.separator_width_for_buffer(bufnr)
  local ok, width = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_rail_separator_width')
  if ok and type(width) == 'number' and width > 0 then
    return width
  end
  return #separator_for()
end

---@param bufnr integer
---@return diffs.RailStyle
function M.style_for_buffer(bufnr)
  local ok, style = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_rail_style')
  if ok and style == 'single' then
    return 'single'
  end
  return 'dual'
end

M._test = {
  format_lnum = format_lnum,
  separator_for = separator_for,
}

return M
