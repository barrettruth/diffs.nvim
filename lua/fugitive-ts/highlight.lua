local M = {}

---@param msg string
---@param ... any
local function dbg(msg, ...)
  local formatted = string.format(msg, ...)
  vim.notify('[fugitive-ts] ' .. formatted, vim.log.levels.DEBUG)
end

---@param bufnr integer
---@param ns integer
---@param hunk fugitive-ts.Hunk
---@param col_offset integer
---@param text string
---@param lang string
---@param debug? boolean
---@return integer
local function highlight_text(bufnr, ns, hunk, col_offset, text, lang, debug)
  local ok, parser_obj = pcall(vim.treesitter.get_string_parser, text, lang)
  if not ok or not parser_obj then
    return 0
  end

  local trees = parser_obj:parse()
  if not trees or #trees == 0 then
    return 0
  end

  local query = vim.treesitter.query.get(lang, 'highlights')
  if not query then
    return 0
  end

  local extmark_count = 0
  local header_line = hunk.start_line - 1

  for id, node, _ in query:iter_captures(trees[1]:root(), text) do
    local capture_name = '@' .. query.captures[id]
    local sr, sc, er, ec = node:range()

    local buf_sr = header_line + sr
    local buf_er = header_line + er
    local buf_sc = col_offset + sc
    local buf_ec = col_offset + ec

    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_sr, buf_sc, {
      end_row = buf_er,
      end_col = buf_ec,
      hl_group = capture_name,
      priority = 200,
    })
    extmark_count = extmark_count + 1
  end

  return extmark_count
end

---@param bufnr integer
---@param ns integer
---@param hunk fugitive-ts.Hunk
---@param max_lines integer
---@param highlight_headers boolean
---@param debug? boolean
function M.highlight_hunk(bufnr, ns, hunk, max_lines, highlight_headers, debug)
  local lang = hunk.lang
  if not lang then
    return
  end

  if #hunk.lines > max_lines then
    if debug then
      dbg(
        'skipping hunk %s:%d (%d lines > %d max)',
        hunk.filename,
        hunk.start_line,
        #hunk.lines,
        max_lines
      )
    end
    return
  end

  ---@type string[]
  local code_lines = {}
  for _, line in ipairs(hunk.lines) do
    table.insert(code_lines, line:sub(2))
  end

  local code = table.concat(code_lines, '\n')
  if code == '' then
    return
  end

  local ok, parser_obj = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser_obj then
    if debug then
      dbg('failed to create parser for lang: %s', lang)
    end
    return
  end

  local trees = parser_obj:parse()
  if not trees or #trees == 0 then
    if debug then
      dbg('parse returned no trees for lang: %s', lang)
    end
    return
  end

  local query = vim.treesitter.query.get(lang, 'highlights')
  if not query then
    if debug then
      dbg('no highlights query for lang: %s', lang)
    end
    return
  end

  if highlight_headers and hunk.header_context and hunk.header_context_col then
    local header_line = hunk.start_line - 1
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, header_line, hunk.header_context_col, {
      end_col = hunk.header_context_col + #hunk.header_context,
      hl_group = 'Normal',
      priority = 199,
    })
    local header_extmarks =
      highlight_text(bufnr, ns, hunk, hunk.header_context_col, hunk.header_context, lang, debug)
    if debug and header_extmarks > 0 then
      dbg('header %s:%d applied %d extmarks', hunk.filename, hunk.start_line, header_extmarks)
    end
  end

  for i, line in ipairs(hunk.lines) do
    local buf_line = hunk.start_line + i - 1
    local line_len = #line
    if line_len > 1 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 1, {
        end_col = line_len,
        hl_group = 'Normal',
        priority = 199,
      })
    end
  end

  local extmark_count = 0
  for id, node, _ in query:iter_captures(trees[1]:root(), code) do
    local capture_name = '@' .. query.captures[id]
    local sr, sc, er, ec = node:range()

    local buf_sr = hunk.start_line + sr
    local buf_er = hunk.start_line + er
    local buf_sc = sc + 1
    local buf_ec = ec + 1

    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_sr, buf_sc, {
      end_row = buf_er,
      end_col = buf_ec,
      hl_group = capture_name,
      priority = 200,
    })
    extmark_count = extmark_count + 1
  end

  if debug then
    dbg('hunk %s:%d applied %d extmarks', hunk.filename, hunk.start_line, extmark_count)
  end
end

return M
