local M = {}

local dbg = require('diffs.log').dbg
local diff = require('diffs.diff')

local PRIORITY_CLEAR = 198
local PRIORITY_SYNTAX = 199
local PRIORITY_LINE_BG = 200
local PRIORITY_CHAR_BG = 201

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

  for id, node, metadata in query:iter_captures(trees[1]:root(), text) do
    local capture_name = '@' .. query.captures[id] .. '.' .. lang
    local sr, sc, er, ec = node:range()

    local buf_sr = header_line + sr
    local buf_er = header_line + er
    local buf_sc = col_offset + sc
    local buf_ec = col_offset + ec

    local priority = lang == 'diff' and (tonumber(metadata.priority) or 100) or PRIORITY_SYNTAX

    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_sr, buf_sc, {
      end_row = buf_er,
      end_col = buf_ec,
      hl_group = capture_name,
      priority = priority,
    })
    extmark_count = extmark_count + 1
  end

  return extmark_count
end

---@class diffs.HunkOpts
---@field hide_prefix boolean
---@field highlights diffs.Highlights

---@param bufnr integer
---@param ns integer
---@param code_lines string[]
---@param lang string
---@param line_map table<integer, integer>
---@param col_offset integer
---@param covered_lines? table<integer, true>
---@return integer
local function highlight_treesitter(
  bufnr,
  ns,
  code_lines,
  lang,
  line_map,
  col_offset,
  covered_lines
)
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

  local extmark_count = 0
  for id, node, metadata in query:iter_captures(trees[1]:root(), code) do
    local capture_name = '@' .. query.captures[id] .. '.' .. lang
    local sr, sc, er, ec = node:range()

    local buf_sr = line_map[sr]
    if buf_sr then
      local buf_er = line_map[er] or buf_sr

      local buf_sc = sc + col_offset
      local buf_ec = ec + col_offset

      local priority = lang == 'diff' and (tonumber(metadata.priority) or 100) or PRIORITY_SYNTAX

      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_sr, buf_sc, {
        end_row = buf_er,
        end_col = buf_ec,
        hl_group = capture_name,
        priority = priority,
      })
      extmark_count = extmark_count + 1
      if covered_lines then
        covered_lines[buf_sr] = true
      end
    end
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
---@param covered_lines? table<integer, true>
---@return integer
local function highlight_vim_syntax(bufnr, ns, hunk, code_lines, covered_lines)
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
      priority = PRIORITY_SYNTAX,
    })
    extmark_count = extmark_count + 1
    if covered_lines then
      covered_lines[buf_line] = true
    end
  end

  return extmark_count
end

---@param bufnr integer
---@param ns integer
---@param hunk diffs.Hunk
---@param opts diffs.HunkOpts
function M.highlight_hunk(bufnr, ns, hunk, opts)
  local use_ts = hunk.lang and opts.highlights.treesitter.enabled
  local use_vim = not use_ts and hunk.ft and opts.highlights.vim.enabled

  local max_lines = use_ts and opts.highlights.treesitter.max_lines or opts.highlights.vim.max_lines
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

  ---@type table<integer, true>
  local covered_lines = {}

  local extmark_count = 0
  if use_ts then
    ---@type string[]
    local new_code = {}
    ---@type table<integer, integer>
    local new_map = {}
    ---@type string[]
    local old_code = {}
    ---@type table<integer, integer>
    local old_map = {}

    for i, line in ipairs(hunk.lines) do
      local prefix = line:sub(1, 1)
      local stripped = line:sub(2)
      local buf_line = hunk.start_line + i - 1

      if prefix == '+' then
        new_map[#new_code] = buf_line
        table.insert(new_code, stripped)
      elseif prefix == '-' then
        old_map[#old_code] = buf_line
        table.insert(old_code, stripped)
      else
        new_map[#new_code] = buf_line
        table.insert(new_code, stripped)
        table.insert(old_code, stripped)
      end
    end

    extmark_count = highlight_treesitter(bufnr, ns, new_code, hunk.lang, new_map, 1, covered_lines)
    extmark_count = extmark_count
      + highlight_treesitter(bufnr, ns, old_code, hunk.lang, old_map, 1, covered_lines)

    if hunk.header_context and hunk.header_context_col then
      local header_line = hunk.start_line - 1
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, header_line, hunk.header_context_col, {
        end_col = hunk.header_context_col + #hunk.header_context,
        hl_group = 'DiffsClear',
        priority = PRIORITY_CLEAR,
      })
      local header_extmarks =
        highlight_text(bufnr, ns, hunk, hunk.header_context_col, hunk.header_context, hunk.lang)
      if header_extmarks > 0 then
        dbg('header %s:%d applied %d extmarks', hunk.filename, hunk.start_line, header_extmarks)
      end
      extmark_count = extmark_count + header_extmarks
    end
  elseif use_vim then
    ---@type string[]
    local code_lines = {}
    for _, line in ipairs(hunk.lines) do
      table.insert(code_lines, line:sub(2))
    end
    extmark_count = highlight_vim_syntax(bufnr, ns, hunk, code_lines, covered_lines)
  end

  if
    hunk.header_start_line
    and hunk.header_lines
    and #hunk.header_lines > 0
    and opts.highlights.treesitter.enabled
  then
    ---@type table<integer, integer>
    local header_map = {}
    for i = 0, #hunk.header_lines - 1 do
      header_map[i] = hunk.header_start_line - 1 + i
    end
    extmark_count = extmark_count
      + highlight_treesitter(bufnr, ns, hunk.header_lines, 'diff', header_map, 0)
  end

  ---@type diffs.IntraChanges?
  local intra = nil
  local intra_cfg = opts.highlights.intra
  if intra_cfg and intra_cfg.enabled and #hunk.lines <= intra_cfg.max_lines then
    dbg('computing intra for hunk %s:%d (%d lines)', hunk.filename, hunk.start_line, #hunk.lines)
    intra = diff.compute_intra_hunks(hunk.lines, intra_cfg.algorithm)
    if intra then
      dbg('intra result: %d add spans, %d del spans', #intra.add_spans, #intra.del_spans)
    else
      dbg('intra result: nil (no change groups)')
    end
  elseif intra_cfg and not intra_cfg.enabled then
    dbg('intra disabled by config')
  elseif intra_cfg and #hunk.lines > intra_cfg.max_lines then
    dbg('intra skipped: %d lines > %d max', #hunk.lines, intra_cfg.max_lines)
  end

  ---@type table<integer, diffs.CharSpan[]>
  local char_spans_by_line = {}
  if intra then
    for _, span in ipairs(intra.add_spans) do
      if not char_spans_by_line[span.line] then
        char_spans_by_line[span.line] = {}
      end
      table.insert(char_spans_by_line[span.line], span)
    end
    for _, span in ipairs(intra.del_spans) do
      if not char_spans_by_line[span.line] then
        char_spans_by_line[span.line] = {}
      end
      table.insert(char_spans_by_line[span.line], span)
    end
  end

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

    if line_len > 1 and covered_lines[buf_line] then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 1, {
        end_col = line_len,
        hl_group = 'DiffsClear',
        priority = PRIORITY_CLEAR,
      })
    end

    if opts.highlights.background and is_diff_line then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, {
        end_col = line_len,
        hl_group = line_hl,
        hl_eol = true,
        number_hl_group = opts.highlights.gutter and number_hl or nil,
        priority = PRIORITY_LINE_BG,
      })
    end

    if char_spans_by_line[i] then
      local char_hl = prefix == '+' and 'DiffsAddText' or 'DiffsDeleteText'
      for _, span in ipairs(char_spans_by_line[i]) do
        dbg(
          'char extmark: line=%d buf_line=%d col=%d..%d hl=%s text="%s"',
          i,
          buf_line,
          span.col_start,
          span.col_end,
          char_hl,
          line:sub(span.col_start + 1, span.col_end)
        )
        local ok, err = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, span.col_start, {
          end_col = span.col_end,
          hl_group = char_hl,
          priority = PRIORITY_CHAR_BG,
        })
        if not ok then
          dbg('char extmark FAILED: %s', err)
        end
        extmark_count = extmark_count + 1
      end
    end
  end

  dbg('hunk %s:%d applied %d extmarks', hunk.filename, hunk.start_line, extmark_count)
end

return M
