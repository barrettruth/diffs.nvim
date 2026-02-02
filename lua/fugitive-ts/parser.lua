---@class fugitive-ts.Hunk
---@field filename string
---@field lang string
---@field start_line integer
---@field header_context string?
---@field header_context_col integer?
---@field lines string[]

local M = {}

local debug_enabled = false

---@param enabled boolean
function M.set_debug(enabled)
  debug_enabled = enabled
end

---@param msg string
---@param ... any
local function dbg(msg, ...)
  if not debug_enabled then
    return
  end
  local formatted = string.format(msg, ...)
  vim.notify('[fugitive-ts] ' .. formatted, vim.log.levels.DEBUG)
end

---@param filename string
---@param custom_langs? table<string, string>
---@param disabled_langs? string[]
---@return string?
local function get_lang_from_filename(filename, custom_langs, disabled_langs)
  if custom_langs and custom_langs[filename] then
    local lang = custom_langs[filename]
    if disabled_langs and vim.tbl_contains(disabled_langs, lang) then
      dbg('lang disabled: %s', lang)
      return nil
    end
    return lang
  end

  local ft = vim.filetype.match({ filename = filename })
  if not ft then
    dbg('no filetype for: %s', filename)
    return nil
  end

  local lang = vim.treesitter.language.get_lang(ft)
  if lang then
    if disabled_langs and vim.tbl_contains(disabled_langs, lang) then
      dbg('lang disabled: %s', lang)
      return nil
    end
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
---@param custom_langs? table<string, string>
---@param disabled_langs? string[]
---@return fugitive-ts.Hunk[]
function M.parse_buffer(bufnr, custom_langs, disabled_langs)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  ---@type fugitive-ts.Hunk[]
  local hunks = {}

  ---@type string?
  local current_filename = nil
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
    if hunk_start and #hunk_lines > 0 and current_lang then
      table.insert(hunks, {
        filename = current_filename,
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
    local filename = line:match('^[MADRC%?!]%s+(.+)$')
    if filename then
      flush_hunk()
      current_filename = filename
      current_lang = get_lang_from_filename(filename, custom_langs, disabled_langs)
      if current_lang then
        dbg('file: %s -> lang: %s', filename, current_lang)
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
