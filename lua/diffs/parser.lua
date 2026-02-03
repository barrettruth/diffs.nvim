---@class diffs.Hunk
---@field filename string
---@field ft string?
---@field lang string?
---@field start_line integer
---@field header_context string?
---@field header_context_col integer?
---@field lines string[]

local M = {}

local dbg = require('diffs.log').dbg

---@param filename string
---@return string?
local function get_ft_from_filename(filename)
  local ft = vim.filetype.match({ filename = filename })
  if not ft then
    dbg('no filetype for: %s', filename)
  end
  return ft
end

---@param ft string
---@return string?
local function get_lang_from_ft(ft)
  local lang = vim.treesitter.language.get_lang(ft)
  if lang then
    local ok = pcall(vim.treesitter.language.inspect, lang)
    if ok then
      return lang
    end
    dbg('no parser for lang: %s (ft: %s)', lang, ft)
  else
    dbg('no ts lang for filetype: %s', ft)
  end
  return nil
end

---@param bufnr integer
---@return diffs.Hunk[]
function M.parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  ---@type diffs.Hunk[]
  local hunks = {}

  ---@type string?
  local current_filename = nil
  ---@type string?
  local current_ft = nil
  ---@type string?
  local current_lang = nil
  ---@type integer?
  local hunk_start = nil
  ---@type string?
  local hunk_header_context = nil
  ---@type integer?
  local hunk_header_context_col = nil
  ---@type string[]
  local hunk_lines = {}

  local function flush_hunk()
    if hunk_start and #hunk_lines > 0 and (current_lang or current_ft) then
      table.insert(hunks, {
        filename = current_filename,
        ft = current_ft,
        lang = current_lang,
        start_line = hunk_start,
        header_context = hunk_header_context,
        header_context_col = hunk_header_context_col,
        lines = hunk_lines,
      })
    end
    hunk_start = nil
    hunk_header_context = nil
    hunk_header_context_col = nil
    hunk_lines = {}
  end

  for i, line in ipairs(lines) do
    local filename = line:match('^[MADRC%?!]%s+(.+)$') or line:match('^diff %-%-git a/.+ b/(.+)$')
    if filename then
      flush_hunk()
      current_filename = filename
      current_ft = get_ft_from_filename(filename)
      current_lang = current_ft and get_lang_from_ft(current_ft) or nil
      if current_lang then
        dbg('file: %s -> lang: %s', filename, current_lang)
      elseif current_ft then
        dbg('file: %s -> ft: %s (no ts parser)', filename, current_ft)
      end
    elseif line:match('^@@.-@@') then
      flush_hunk()
      hunk_start = i
      local prefix, context = line:match('^(@@.-@@%s*)(.*)')
      if context and context ~= '' then
        hunk_header_context = context
        hunk_header_context_col = #prefix
      end
    elseif hunk_start then
      local prefix = line:sub(1, 1)
      if prefix == ' ' or prefix == '+' or prefix == '-' then
        table.insert(hunk_lines, line)
      elseif
        line == ''
        or line:match('^[MADRC%?!]%s+')
        or line:match('^diff ')
        or line:match('^index ')
        or line:match('^Binary ')
      then
        flush_hunk()
        current_filename = nil
        current_ft = nil
        current_lang = nil
      end
    end
  end

  flush_hunk()

  return hunks
end

return M
