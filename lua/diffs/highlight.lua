local M = {}

local dbg = require('diffs.log').dbg
local diff = require('diffs.diff')

---@param bufnr integer
---@param ns integer
---@param hunk diffs.Hunk
---@param col_offset integer
---@param text string
---@param lang string
---@param context_lines? string[]
---@param priorities diffs.PrioritiesConfig
---@return integer
local function highlight_text(bufnr, ns, hunk, col_offset, text, lang, context_lines, priorities)
  local parse_text = text
  if context_lines and #context_lines > 0 then
    parse_text = text .. '\n' .. table.concat(context_lines, '\n')
  end

  local ok, parser_obj = pcall(vim.treesitter.get_string_parser, parse_text, lang)
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

  for id, node, metadata in query:iter_captures(trees[1]:root(), parse_text) do
    local sr, sc, _, ec = node:range()
    if sr == 0 then
      local capture_name = '@' .. query.captures[id] .. '.' .. lang

      local buf_sr = header_line
      local buf_er = header_line
      local buf_sc = col_offset + sc
      local buf_ec = col_offset + ec

      local priority = lang == 'diff' and (tonumber(metadata.priority) or 100) or priorities.syntax

      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_sr, buf_sc, {
        end_row = buf_er,
        end_col = buf_ec,
        hl_group = capture_name,
        priority = priority,
      })
      extmark_count = extmark_count + 1
    end
  end

  return extmark_count
end

---@class diffs.HunkOpts
---@field hide_prefix boolean
---@field highlights diffs.Highlights
---@field defer_vim_syntax? boolean
---@field syntax_only? boolean

---@param bufnr integer
---@param ns integer
---@param code_lines string[]
---@param lang string
---@param line_map table<integer, integer>
---@param col_offset integer
---@param covered_lines? table<integer, true>
---@param priorities diffs.PrioritiesConfig
---@param force_high_priority? boolean
---@return integer
local function highlight_treesitter(
  bufnr,
  ns,
  code_lines,
  lang,
  line_map,
  col_offset,
  covered_lines,
  priorities,
  force_high_priority
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

  local trees = parser_obj:parse(true)
  if not trees or #trees == 0 then
    dbg('parse returned no trees for lang: %s', lang)
    return 0
  end

  local extmark_count = 0
  parser_obj:for_each_tree(function(tree, ltree)
    local tree_lang = ltree:lang()
    local query = vim.treesitter.query.get(tree_lang, 'highlights')
    if not query then
      return
    end

    for id, node, metadata in query:iter_captures(tree:root(), code) do
      local capture = query.captures[id]
      if capture ~= 'spell' and capture ~= 'nospell' then
        local capture_name = '@' .. capture .. '.' .. tree_lang
        local sr, sc, er, ec = node:range()

        local buf_sr = line_map[sr]
        if buf_sr then
          local buf_er = line_map[er] or buf_sr

          local buf_sc = sc + col_offset
          local buf_ec = ec + col_offset

          local meta_prio = tonumber(metadata.priority) or 100
          local priority = tree_lang == 'diff'
              and ((col_offset > 0 or force_high_priority) and (priorities.syntax + meta_prio - 100) or meta_prio)
            or priorities.syntax

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
    end
  end)

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
---@param leading_offset? integer
---@param priorities diffs.PrioritiesConfig
---@return integer
local function highlight_vim_syntax(
  bufnr,
  ns,
  hunk,
  code_lines,
  covered_lines,
  leading_offset,
  priorities
)
  local ft = hunk.ft
  if not ft then
    return 0
  end

  if #code_lines == 0 then
    return 0
  end

  leading_offset = leading_offset or 0

  local scratch = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, code_lines)
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = scratch })

  local spans = {}

  pcall(vim.api.nvim_buf_call, scratch, function()
    vim.cmd('setlocal syntax=' .. ft)
    vim.cmd.redraw()

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

  pcall(vim.api.nvim_buf_delete, scratch, { force = true })

  local hunk_line_count = #hunk.lines
  local col_off = (hunk.prefix_width or 1) + (hunk.quote_width or 0) - 1
  local extmark_count = 0
  for _, span in ipairs(spans) do
    local adj = span.line - leading_offset
    if adj >= 1 and adj <= hunk_line_count then
      local buf_line = hunk.start_line + adj - 1
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, span.col_start + col_off, {
        end_col = span.col_end + col_off,
        hl_group = span.hl_name,
        priority = priorities.syntax,
      })
      extmark_count = extmark_count + 1
      if covered_lines then
        covered_lines[buf_line] = true
      end
    end
  end

  return extmark_count
end

---@param bufnr integer
---@param ns integer
---@param hunk diffs.Hunk
---@param opts diffs.HunkOpts
function M.highlight_hunk(bufnr, ns, hunk, opts)
  local p = opts.highlights.priorities
  local pw = hunk.prefix_width or 1
  local qw = hunk.quote_width or 0
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

  if use_vim and opts.defer_vim_syntax then
    use_vim = false
  end

  ---@type table<integer, true>
  local covered_lines = {}

  local extmark_count = 0
  ---@type string[]
  local new_code = {}

  if use_ts then
    ---@type table<integer, integer>
    local new_map = {}
    ---@type string[]
    local old_code = {}
    ---@type table<integer, integer>
    local old_map = {}

    for i, line in ipairs(hunk.lines) do
      local prefix = line:sub(1, pw)
      local stripped = line:sub(pw + 1)
      local buf_line = hunk.start_line + i - 1
      local has_add = prefix:find('+', 1, true) ~= nil
      local has_del = prefix:find('-', 1, true) ~= nil

      if has_add and not has_del then
        new_map[#new_code] = buf_line
        table.insert(new_code, stripped)
      elseif has_del and not has_add then
        old_map[#old_code] = buf_line
        table.insert(old_code, stripped)
      else
        new_map[#new_code] = buf_line
        table.insert(new_code, stripped)
        table.insert(old_code, stripped)
      end
    end

    extmark_count =
      highlight_treesitter(bufnr, ns, new_code, hunk.lang, new_map, pw + qw, covered_lines, p)
    extmark_count = extmark_count
      + highlight_treesitter(bufnr, ns, old_code, hunk.lang, old_map, pw + qw, covered_lines, p)

    if hunk.header_context and hunk.header_context_col then
      local header_extmarks = highlight_text(
        bufnr,
        ns,
        hunk,
        hunk.header_context_col,
        hunk.header_context,
        hunk.lang,
        new_code,
        p
      )
      if header_extmarks > 0 then
        dbg('header %s:%d applied %d extmarks', hunk.filename, hunk.start_line, header_extmarks)
      end
      extmark_count = extmark_count + header_extmarks
    end
  elseif use_vim then
    ---@type string[]
    local code_lines = {}
    for _, line in ipairs(hunk.lines) do
      table.insert(code_lines, line:sub(pw + 1))
    end
    extmark_count = highlight_vim_syntax(bufnr, ns, hunk, code_lines, covered_lines, 0, p)
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
      + highlight_treesitter(
        bufnr,
        ns,
        hunk.header_lines,
        'diff',
        header_map,
        qw,
        nil,
        p,
        qw > 0 or pw > 1
      )
  end

  local at_raw_line
  if (qw > 0 or pw > 1) and opts.highlights.treesitter.enabled then
    local at_buf_line = hunk.start_line - 1
    at_raw_line = vim.api.nvim_buf_get_lines(bufnr, at_buf_line, at_buf_line + 1, false)[1]
  end

  ---@type diffs.IntraChanges?
  local intra = nil
  local intra_cfg = opts.highlights.intra
  if
    not opts.syntax_only
    and intra_cfg
    and intra_cfg.enabled
    and pw == 1
    and #hunk.lines <= intra_cfg.max_lines
  then
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

  if
    (qw > 0 or pw > 1)
    and hunk.header_start_line
    and hunk.header_lines
    and #hunk.header_lines > 0
    and opts.highlights.treesitter.enabled
  then
    for i = 0, #hunk.header_lines - 1 do
      local buf_line = hunk.header_start_line - 1 + i
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, {
        end_col = #hunk.header_lines[i + 1] + qw,
        hl_group = 'DiffsClear',
        priority = p.clear,
      })

      if pw > 1 then
        local hline = hunk.header_lines[i + 1]
        if hline:match('^index ') then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, qw, {
            end_col = 5 + qw,
            hl_group = '@keyword.diff',
            priority = p.syntax,
          })
          local dot_pos = hline:find('%.%.', 1, false)
          if dot_pos then
            local rest = hline:sub(dot_pos + 2)
            local hash = rest:match('^(%x+)')
            if hash then
              pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, dot_pos + 1 + qw, {
                end_col = dot_pos + 1 + #hash + qw,
                hl_group = '@constant.diff',
                priority = p.syntax,
              })
            end
          end
        end
      end
    end
  end

  if (qw > 0 or pw > 1) and at_raw_line then
    local at_buf_line = hunk.start_line - 1
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, at_buf_line, 0, {
      end_col = #at_raw_line,
      hl_group = 'DiffsClear',
      priority = p.clear,
    })
    if opts.highlights.treesitter.enabled then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, at_buf_line, qw, {
        end_col = #at_raw_line,
        hl_group = '@attribute.diff',
        priority = p.syntax,
      })
    end
  end

  if use_ts and hunk.header_context and hunk.header_context_col then
    local header_line = hunk.start_line - 1
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, header_line, hunk.header_context_col, {
      end_col = hunk.header_context_col + #hunk.header_context,
      hl_group = 'DiffsClear',
      priority = p.clear,
    })
  end

  local raw_body_lines
  if qw > 0 then
    raw_body_lines =
      vim.api.nvim_buf_get_lines(bufnr, hunk.start_line, hunk.start_line + #hunk.lines, false)
  end

  for i, line in ipairs(hunk.lines) do
    local buf_line = hunk.start_line + i - 1
    local line_len = #line
    local raw_len = raw_body_lines and #raw_body_lines[i] or nil
    local prefix = line:sub(1, pw)
    local has_add = prefix:find('+', 1, true) ~= nil
    local has_del = prefix:find('-', 1, true) ~= nil
    local is_diff_line = has_add or has_del
    local line_hl = is_diff_line and (has_add and 'DiffsAdd' or 'DiffsDelete') or nil
    local number_hl = is_diff_line and (has_add and 'DiffsAddNr' or 'DiffsDeleteNr') or nil

    local is_marker = false
    if pw > 1 and line_hl and not prefix:find('[^+]') then
      local content = line:sub(pw + 1)
      is_marker = content:match('^<<<<<<<')
        or content:match('^=======')
        or content:match('^>>>>>>>')
        or content:match('^|||||||')
    end

    if not opts.syntax_only then
      if opts.hide_prefix then
        local virt_hl = (opts.highlights.background and line_hl) or nil
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, {
          virt_text = { { string.rep(' ', pw + qw), virt_hl } },
          virt_text_pos = 'overlay',
        })
      end

      if qw > 0 or pw > 1 then
        local prefix_end = pw + qw
        if raw_len and prefix_end > raw_len then
          prefix_end = raw_len
        end
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, {
          end_col = prefix_end,
          hl_group = 'DiffsClear',
          priority = p.clear,
        })
        for ci = 0, pw - 1 do
          local ch = line:sub(ci + 1, ci + 1)
          if ch == '+' or ch == '-' then
            local char_col = ci + qw
            if raw_len and char_col >= raw_len then
              break
            end
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, char_col, {
              end_col = char_col + 1,
              hl_group = ch == '+' and '@diff.plus' or '@diff.minus',
              priority = p.syntax,
            })
          end
        end
      end

      if opts.highlights.background and is_diff_line then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, 0, {
          line_hl_group = line_hl,
          number_hl_group = opts.highlights.gutter and number_hl or nil,
          priority = p.line_bg,
        })
      end

      if is_marker and line_len > pw then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, pw + qw, {
          end_col = line_len + qw,
          hl_group = 'DiffsConflictMarker',
          priority = p.char_bg,
        })
      end

      if char_spans_by_line[i] then
        local char_hl = has_add and 'DiffsAddText' or 'DiffsDeleteText'
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
          local ok, err =
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, span.col_start + qw, {
              end_col = span.col_end + qw,
              hl_group = char_hl,
              priority = p.char_bg,
            })
          if not ok then
            dbg('char extmark FAILED: %s', err)
          end
          extmark_count = extmark_count + 1
        end
      end
    end

    if line_len > pw and covered_lines[buf_line] then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_line, pw + qw, {
        end_col = line_len + qw,
        hl_group = 'DiffsClear',
        priority = p.clear,
      })
    end
  end

  dbg('hunk %s:%d applied %d extmarks', hunk.filename, hunk.start_line, extmark_count)
end

return M
