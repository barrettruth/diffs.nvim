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

---@param bufnr integer
---@param ns integer
---@param hunk fugitive-ts.Hunk
---@param col_offset integer
---@param text string
---@param lang string
---@return integer
local function highlight_text(bufnr, ns, hunk, col_offset, text, lang)
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

---@class fugitive-ts.HunkOpts
---@field hide_prefix boolean
---@field treesitter fugitive-ts.TreesitterConfig
---@field vim fugitive-ts.VimConfig
---@field highlights fugitive-ts.Highlights

---@param bufnr integer
---@param ns integer
---@param hunk fugitive-ts.Hunk
---@param opts fugitive-ts.HunkOpts
function M.highlight_hunk(bufnr, ns, hunk, opts)
  local lang = hunk.lang
  if not lang then
    return
  end

  local max_lines = opts.treesitter.max_lines
  if #hunk.lines > max_lines then
    dbg(
      'skipping hunk %s:%d (%d lines > %d max)',
      hunk.filename,
      hunk.start_line,
      #hunk.lines,
      max_lines
    )
    return
  end

  for i, line in ipairs(hunk.lines) do
    local buf_line = hunk.start_line + i - 1
    local line_len = #line
    local prefix = line:sub(1, 1)

    local is_diff_line = prefix == '+' or prefix == '-'
    local line_hl = is_diff_line and (prefix == '+' and 'FugitiveTsAdd' or 'FugitiveTsDelete')
      or nil
    local number_hl = is_diff_line and (prefix == '+' and 'FugitiveTsAddNr' or 'FugitiveTsDeleteNr')
      or nil

    if opts.hide_prefix then
      local virt_hl = (opts.highlights.background and line_hl) or nil
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, {
        virt_text = { { ' ', virt_hl } },
        virt_text_pos = 'overlay',
      })
    end

    if opts.highlights.background and is_diff_line then
      local extmark_opts = {
        line_hl_group = line_hl,
        priority = 198,
      }
      if opts.highlights.gutter then
        extmark_opts.number_hl_group = number_hl
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, extmark_opts)
    end

    if line_len > 1 and opts.treesitter.enabled then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 1, {
        end_col = line_len,
        hl_group = 'Normal',
        priority = 199,
      })
    end
  end

  if not opts.treesitter.enabled then
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
    dbg('failed to create parser for lang: %s', lang)
    return
  end

  local trees = parser_obj:parse()
  if not trees or #trees == 0 then
    dbg('parse returned no trees for lang: %s', lang)
    return
  end

  local query = vim.treesitter.query.get(lang, 'highlights')
  if not query then
    dbg('no highlights query for lang: %s', lang)
    return
  end

  if hunk.header_context and hunk.header_context_col then
    local header_line = hunk.start_line - 1
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, header_line, hunk.header_context_col, {
      end_col = hunk.header_context_col + #hunk.header_context,
      hl_group = 'Normal',
      priority = 199,
    })
    local header_extmarks =
      highlight_text(bufnr, ns, hunk, hunk.header_context_col, hunk.header_context, lang)
    if header_extmarks > 0 then
      dbg('header %s:%d applied %d extmarks', hunk.filename, hunk.start_line, header_extmarks)
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

  dbg('hunk %s:%d applied %d extmarks', hunk.filename, hunk.start_line, extmark_count)
end

return M
