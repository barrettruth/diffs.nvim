local M = {}

local hunk_model = require('diffs.hunks')

---@class diffs.RailInfo
---@field width integer
---@field prefix_width integer

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
  local prefix_width = width + 1 + width + 3
  local annotated = {}

  for lnum, text in ipairs(lines) do
    local line = by_lnum[lnum]
    annotated[lnum] = format_lnum(old_lnum(line), width)
      .. ' '
      .. format_lnum(new_lnum(line), width)
      .. ' | '
      .. text
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
  return line:sub(prefix_width + 1)
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
