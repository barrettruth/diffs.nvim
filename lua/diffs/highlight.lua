local M = {}

local dbg = require('diffs.log').dbg

---@param bufnr integer
---@param ns integer
---@param hunk diffs.Hunk
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

---@class diffs.HunkOpts
---@field hide_prefix boolean
---@field treesitter diffs.TreesitterConfig
---@field vim diffs.VimConfig
---@field highlights diffs.Highlights

---@param bufnr integer
---@param ns integer
---@param hunk diffs.Hunk
---@param code_lines string[]
---@return integer
local function highlight_treesitter(bufnr, ns, hunk, code_lines)
  local lang = hunk.lang
  if not lang then
    return 0
  end

  local code = table.concat(code_lines, '\n')
  if code == '' then
    return 0
  end

  local ok, parser_obj = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser_obj then
    dbg('failed to create parser for lang: %s', lang)
    return 0
  end

  local trees = parser_obj:parse()
  if not trees or #trees == 0 then
    dbg('parse returned no trees for lang: %s', lang)
    return 0
  end

  local query = vim.treesitter.query.get(lang, 'highlights')
  if not query then
    dbg('no highlights query for lang: %s', lang)
    return 0
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

  return extmark_count
end

---@alias diffs.SyntaxQueryFn fun(line: integer, col: integer): integer, string

---@param query_fn diffs.SyntaxQueryFn
---@param code_lines string[]
---@return {line: integer, col_start: integer, col_end: integer, hl_name: string}[]
function M.coalesce_syntax_spans(query_fn, code_lines)
  local spans = {}
  for i, line in ipairs(code_lines) do
    local col = 1
    local line_len = #line

    while col <= line_len do
      local syn_id, hl_name = query_fn(i, col)
      if syn_id == 0 then
        col = col + 1
      else
        local span_start = col

        col = col + 1
        while col <= line_len do
          local next_id, next_name = query_fn(i, col)
          if next_id == 0 or next_name ~= hl_name then
            break
          end
          col = col + 1
        end

        if hl_name ~= '' then
          table.insert(spans, {
            line = i,
            col_start = span_start,
            col_end = col,
            hl_name = hl_name,
          })
        end
      end
    end
  end
  return spans
end

---@param bufnr integer
---@param ns integer
---@param hunk diffs.Hunk
---@param code_lines string[]
---@return integer
local function highlight_vim_syntax(bufnr, ns, hunk, code_lines)
  local ft = hunk.ft
  if not ft then
    return 0
  end

  if #code_lines == 0 then
    return 0
  end

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, code_lines)
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = scratch })

  local spans = {}

  vim.api.nvim_buf_call(scratch, function()
    vim.cmd('setlocal syntax=' .. ft)
    vim.cmd('redraw')

    ---@param line integer
    ---@param col integer
    ---@return integer, string
    local function query_fn(line, col)
      local syn_id = vim.fn.synID(line, col, 1)
      if syn_id == 0 then
        return 0, ''
      end
      return syn_id, vim.fn.synIDattr(vim.fn.synIDtrans(syn_id), 'name')
    end

    spans = M.coalesce_syntax_spans(query_fn, code_lines)
  end)

  vim.api.nvim_buf_delete(scratch, { force = true })

  local extmark_count = 0
  for _, span in ipairs(spans) do
    local buf_line = hunk.start_line + span.line - 1
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, span.col_start, {
      end_col = span.col_end,
      hl_group = span.hl_name,
      priority = 200,
    })
    extmark_count = extmark_count + 1
  end

  return extmark_count
end

---@param bufnr integer
---@param ns integer
---@param hunk diffs.Hunk
---@param opts diffs.HunkOpts
function M.highlight_hunk(bufnr, ns, hunk, opts)
  local use_ts = hunk.lang and opts.treesitter.enabled
  local use_vim = not use_ts and hunk.ft and opts.vim.enabled

  local max_lines = use_ts and opts.treesitter.max_lines or opts.vim.max_lines
  if (use_ts or use_vim) and #hunk.lines > max_lines then
    dbg(
      'skipping hunk %s:%d (%d lines > %d max)',
      hunk.filename,
      hunk.start_line,
      #hunk.lines,
      max_lines
    )
    use_ts = false
    use_vim = false
  end

  local apply_syntax = use_ts or use_vim

  ---@type string[]
  local code_lines = {}
  if apply_syntax then
    for _, line in ipairs(hunk.lines) do
      table.insert(code_lines, line:sub(2))
    end
  end

  local extmark_count = 0
  if use_ts then
    extmark_count = highlight_treesitter(bufnr, ns, hunk, code_lines)
  elseif use_vim then
    extmark_count = highlight_vim_syntax(bufnr, ns, hunk, code_lines)
  end

  local syntax_applied = extmark_count > 0

  for i, line in ipairs(hunk.lines) do
    local buf_line = hunk.start_line + i - 1
    local line_len = #line
    local prefix = line:sub(1, 1)

    local is_diff_line = prefix == '+' or prefix == '-'
    local line_hl = is_diff_line and (prefix == '+' and 'DiffsAdd' or 'DiffsDelete') or nil
    local number_hl = is_diff_line and (prefix == '+' and 'DiffsAddNr' or 'DiffsDeleteNr') or nil

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

    if line_len > 1 and syntax_applied then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 1, {
        end_col = line_len,
        hl_group = 'Normal',
        priority = 199,
      })
    end
  end

  dbg('hunk %s:%d applied %d extmarks', hunk.filename, hunk.start_line, extmark_count)
end

return M
