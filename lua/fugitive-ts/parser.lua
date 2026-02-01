---@class fugitive-ts.Hunk
---@field filename string
---@field lang string
---@field start_line integer
---@field lines string[]

local M = {}

---@param filename string
---@param custom_langs? table<string, string>
---@return string?
local function get_lang_from_filename(filename, custom_langs)
  if custom_langs and custom_langs[filename] then
    return custom_langs[filename]
  end

  local ft = vim.filetype.match({ filename = filename })
  if not ft then
    return nil
  end

  local lang = vim.treesitter.language.get_lang(ft)
  if lang then
    local ok = pcall(vim.treesitter.language.inspect, lang)
    if ok then
      return lang
    end
  end

  return nil
end

---@param bufnr integer
---@param custom_langs? table<string, string>
---@return fugitive-ts.Hunk[]
function M.parse_buffer(bufnr, custom_langs)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  ---@type fugitive-ts.Hunk[]
  local hunks = {}

  ---@type string?
  local current_filename = nil
  ---@type string?
  local current_lang = nil
  ---@type integer?
  local hunk_start = nil
  ---@type string[]
  local hunk_lines = {}

  local function flush_hunk()
    if hunk_start and #hunk_lines > 0 and current_lang then
      table.insert(hunks, {
        filename = current_filename,
        lang = current_lang,
        start_line = hunk_start,
        lines = hunk_lines,
      })
    end
    hunk_start = nil
    hunk_lines = {}
  end

  for i, line in ipairs(lines) do
    local filename = line:match('^[MADRC%?!]%s+(.+)$')
    if filename then
      flush_hunk()
      current_filename = filename
      current_lang = get_lang_from_filename(filename, custom_langs)
    elseif line:match('^@@.-@@') then
      flush_hunk()
      hunk_start = i
    elseif hunk_start then
      local prefix = line:sub(1, 1)
      if prefix == ' ' or prefix == '+' or prefix == '-' then
        table.insert(hunk_lines, line)
      elseif line == '' or line:match('^[MADRC%?!]%s+') or line:match('^%a') then
        flush_hunk()
        current_filename = nil
        current_lang = nil
      end
    end
  end

  flush_hunk()

  return hunks
end

return M
