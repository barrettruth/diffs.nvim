local M = {}

---@class diffs.ContentLines: string[]
---@field _diffs_has_final_newline? boolean

---@class diffs.ContentFromRawOpts
---@field empty_is_empty? boolean

---@param lines string[]
---@param has_final_newline boolean?
---@return diffs.ContentLines
local function content_lines(lines, has_final_newline)
  local result = {}
  for i, line in ipairs(lines) do
    result[i] = line
  end
  if has_final_newline then
    result._diffs_has_final_newline = true
  end
  return result
end

---@param lines diffs.ContentLines|string[]?
---@return boolean
local function has_final_newline(lines)
  return type(lines) == 'table' and lines._diffs_has_final_newline == true
end

---@param lines string[]
---@param opts? diffs.ContentFromRawOpts
---@return diffs.ContentLines
function M.from_raw_lines(lines, opts)
  opts = opts or {}
  local result = {}
  for i, line in ipairs(lines) do
    result[i] = line
  end

  if opts.empty_is_empty and #result == 1 and result[1] == '' then
    result = {}
  end

  local ends_with_final_newline = #result > 0 and result[#result] == ''
  if ends_with_final_newline then
    result[#result] = nil
  end

  return content_lines(result, ends_with_final_newline)
end

---@param bufnr integer
---@param lines string[]
---@return boolean
local function buffer_has_final_newline(bufnr, lines)
  if not vim.api.nvim_get_option_value('endofline', { buf = bufnr }) then
    return false
  end

  if #lines == 1 and lines[1] == '' then
    local byte_count = vim.api.nvim_buf_call(bufnr, function()
      return vim.fn.wordcount().bytes
    end)
    return byte_count > 0
  end

  return true
end

---@param bufnr integer
---@return diffs.ContentLines
function M.from_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return content_lines(lines, buffer_has_final_newline(bufnr, lines))
end

---@param lines diffs.ContentLines|string[]
---@return string
function M.to_string(lines)
  local text = table.concat(lines, '\n')
  if has_final_newline(lines) then
    text = text .. '\n'
  end
  return text
end

return M
