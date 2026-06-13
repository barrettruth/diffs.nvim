---@class diffs.CharSpan
---@field line integer
---@field col_start integer
---@field col_end integer

---@class diffs.IntraChanges
---@field add_spans diffs.CharSpan[]
---@field del_spans diffs.CharSpan[]

---@class diffs.ChangeGroup
---@field del_lines {idx: integer, text: string}[]
---@field add_lines {idx: integer, text: string}[]

local M = {}

local dbg = require('diffs.log').dbg
local notify = require('diffs.log').notify
local diffopt = require('diffs.diffopt')

local warned_vscode_whitespace = false

---@param hunk_lines string[]
---@return diffs.ChangeGroup[]
function M.extract_change_groups(hunk_lines)
  ---@type diffs.ChangeGroup[]
  local groups = {}
  ---@type {idx: integer, text: string}[]
  local del_buf = {}
  ---@type {idx: integer, text: string}[]
  local add_buf = {}

  ---@type boolean
  local in_del = false

  for i, line in ipairs(hunk_lines) do
    local prefix = line:sub(1, 1)
    if prefix == '-' then
      if not in_del and #add_buf > 0 then
        if #del_buf > 0 then
          table.insert(groups, { del_lines = del_buf, add_lines = add_buf })
        end
        del_buf = {}
        add_buf = {}
      end
      in_del = true
      table.insert(del_buf, { idx = i, text = line:sub(2) })
    elseif prefix == '+' then
      in_del = false
      table.insert(add_buf, { idx = i, text = line:sub(2) })
    else
      if #del_buf > 0 and #add_buf > 0 then
        table.insert(groups, { del_lines = del_buf, add_lines = add_buf })
      end
      del_buf = {}
      add_buf = {}
      in_del = false
    end
  end

  if #del_buf > 0 and #add_buf > 0 then
    table.insert(groups, { del_lines = del_buf, add_lines = add_buf })
  end

  return groups
end

---@param old_text string
---@param new_text string
---@param diff_opts? diffs.DiffOpts
---@return {old_start: integer, old_count: integer, new_start: integer, new_count: integer}[]
local function byte_diff(old_text, new_text, diff_opts)
  local vim_opts = { result_type = 'indices' }
  if diff_opts then
    if diff_opts.algorithm then
      vim_opts.algorithm = diff_opts.algorithm
    end
    if diff_opts.linematch then
      vim_opts.linematch = diff_opts.linematch
    end
  end
  local ok, result = pcall(vim.diff, old_text, new_text, vim_opts)
  if not ok or not result then
    return {}
  end
  ---@type {old_start: integer, old_count: integer, new_start: integer, new_count: integer}[]
  local hunks = {}
  for _, h in ipairs(result) do
    table.insert(hunks, {
      old_start = h[1],
      old_count = h[2],
      new_start = h[3],
      new_count = h[4],
    })
  end
  return hunks
end

---@param s string
---@return string[]
local function split_bytes(s)
  local bytes = {}
  for i = 1, #s do
    table.insert(bytes, s:sub(i, i))
  end
  return bytes
end

--- Drop intra-line spans whose covered text is purely whitespace, so that
--- whitespace-only character differences are not highlighted while 'diffopt'
--- ignores whitespace. The byte-level differ cannot express this itself, so it
--- is filtered from the resulting spans.
---@param spans diffs.CharSpan[]
---@param line string
---@param diff_opts diffs.DiffOpts
---@return diffs.CharSpan[]
local function drop_whitespace_spans(spans, line, diff_opts)
  local ignore_all = diff_opts.ignore_whitespace
  local ignore_eol = diff_opts.ignore_whitespace_change_at_eol
  if not (ignore_all or ignore_eol) then
    return spans
  end
  local kept = {}
  for _, span in ipairs(spans) do
    local text = line:sub(span.col_start, span.col_end - 1)
    local whitespace_only = text:match('^%s*$') ~= nil
    local drop
    if ignore_all then
      drop = whitespace_only
    else
      drop = whitespace_only and span.col_end > #line
    end
    if not drop then
      kept[#kept + 1] = span
    end
  end
  return kept
end

---@param old_line string
---@param new_line string
---@param del_idx integer
---@param add_idx integer
---@param diff_opts? diffs.DiffOpts
---@return diffs.CharSpan[], diffs.CharSpan[]
local function char_diff_pair(old_line, new_line, del_idx, add_idx, diff_opts)
  ---@type diffs.CharSpan[]
  local del_spans = {}
  ---@type diffs.CharSpan[]
  local add_spans = {}

  local old_bytes = split_bytes(old_line)
  local new_bytes = split_bytes(new_line)

  local old_text = table.concat(old_bytes, '\n') .. '\n'
  local new_text = table.concat(new_bytes, '\n') .. '\n'

  local char_opts = diff_opts
  if diff_opts and diff_opts.linematch then
    char_opts = { algorithm = diff_opts.algorithm }
  end

  local char_hunks = byte_diff(old_text, new_text, char_opts)

  for _, ch in ipairs(char_hunks) do
    if ch.old_count > 0 then
      table.insert(del_spans, {
        line = del_idx,
        col_start = ch.old_start,
        col_end = ch.old_start + ch.old_count,
      })
    end

    if ch.new_count > 0 then
      table.insert(add_spans, {
        line = add_idx,
        col_start = ch.new_start,
        col_end = ch.new_start + ch.new_count,
      })
    end
  end

  if diff_opts then
    del_spans = drop_whitespace_spans(del_spans, old_line, diff_opts)
    add_spans = drop_whitespace_spans(add_spans, new_line, diff_opts)
  end

  return del_spans, add_spans
end

---@class diffs.LinePair
---@field del {idx: integer, text: string}
---@field add {idx: integer, text: string}

--- Pair up the removed and added lines of a change group so they can be diffed
--- (or classified) against each other. A 1:1 group pairs directly; larger
--- groups are line-mapped with a block-level vim.diff() so equal-count runs line
--- up and unequal-count runs pair as many as possible.
---@param group diffs.ChangeGroup
---@param diff_opts? diffs.DiffOpts
---@return diffs.LinePair[]
local function pair_group_lines(group, diff_opts)
  if #group.del_lines == 1 and #group.add_lines == 1 then
    return { { del = group.del_lines[1], add = group.add_lines[1] } }
  end

  local old_texts = {}
  for _, l in ipairs(group.del_lines) do
    table.insert(old_texts, l.text)
  end
  local new_texts = {}
  for _, l in ipairs(group.add_lines) do
    table.insert(new_texts, l.text)
  end

  local old_block = table.concat(old_texts, '\n') .. '\n'
  local new_block = table.concat(new_texts, '\n') .. '\n'

  local pair_opts = diff_opts
  if diff_opts and diff_opts.linematch then
    pair_opts = { algorithm = diff_opts.algorithm }
  end
  local line_hunks = byte_diff(old_block, new_block, pair_opts)

  ---@type diffs.LinePair[]
  local pairs_out = {}
  for _, lh in ipairs(line_hunks) do
    local count = (lh.old_count == lh.new_count) and lh.old_count
      or math.min(lh.old_count, lh.new_count)
    for k = 0, count - 1 do
      local del = group.del_lines[lh.old_start + k]
      local add = group.add_lines[lh.new_start + k]
      if del and add then
        table.insert(pairs_out, { del = del, add = add })
      end
    end
  end
  return pairs_out
end

---@param group diffs.ChangeGroup
---@param diff_opts? diffs.DiffOpts
---@return diffs.CharSpan[], diffs.CharSpan[]
local function diff_group_native(group, diff_opts)
  ---@type diffs.CharSpan[]
  local all_del = {}
  ---@type diffs.CharSpan[]
  local all_add = {}

  for _, pr in ipairs(pair_group_lines(group, diff_opts)) do
    local ds, as = char_diff_pair(pr.del.text, pr.add.text, pr.del.idx, pr.add.idx, diff_opts)
    vim.list_extend(all_del, ds)
    vim.list_extend(all_add, as)
  end

  return all_del, all_add
end

---@param group diffs.ChangeGroup
---@param handle table
---@param diff_opts? diffs.DiffOpts
---@return diffs.CharSpan[], diffs.CharSpan[]
local function diff_group_vscode(group, handle, diff_opts)
  ---@type diffs.CharSpan[]
  local all_del = {}
  ---@type diffs.CharSpan[]
  local all_add = {}

  local ffi = require('ffi')

  local old_texts = {}
  for _, l in ipairs(group.del_lines) do
    table.insert(old_texts, l.text)
  end
  local new_texts = {}
  for _, l in ipairs(group.add_lines) do
    table.insert(new_texts, l.text)
  end

  local orig_arr = ffi.new('const char*[?]', #old_texts)
  for i, t in ipairs(old_texts) do
    orig_arr[i - 1] = t
  end

  local mod_arr = ffi.new('const char*[?]', #new_texts)
  for i, t in ipairs(new_texts) do
    mod_arr[i - 1] = t
  end

  local ignore_trim = false
  if diff_opts then
    ignore_trim = diff_opts.ignore_whitespace == true
      or diff_opts.ignore_whitespace_change == true
      or diff_opts.ignore_whitespace_change_at_eol == true
  end

  local opts = ffi.new('DiffsDiffOptions', {
    ignore_trim_whitespace = ignore_trim,
    max_computation_time_ms = 1000,
    compute_moves = false,
    extend_to_subwords = false,
  })

  local result = handle.compute_diff(orig_arr, #old_texts, mod_arr, #new_texts, opts)
  if result == nil then
    return all_del, all_add
  end

  for ci = 0, result.changes.count - 1 do
    local mapping = result.changes.mappings[ci]
    for ii = 0, mapping.inner_change_count - 1 do
      local inner = mapping.inner_changes[ii]

      local orig_line = inner.original.start_line
      if group.del_lines[orig_line] then
        table.insert(all_del, {
          line = group.del_lines[orig_line].idx,
          col_start = inner.original.start_col,
          col_end = inner.original.end_col,
        })
      end

      local mod_line = inner.modified.start_line
      if group.add_lines[mod_line] then
        table.insert(all_add, {
          line = group.add_lines[mod_line].idx,
          col_start = inner.modified.start_col,
          col_end = inner.modified.end_col,
        })
      end
    end
  end

  handle.free_lines_diff(result)

  return all_del, all_add
end

---@param hunk_lines string[]
---@param algorithm? string
---@return diffs.IntraChanges?
function M.compute_intra_hunks(hunk_lines, algorithm)
  local groups = M.extract_change_groups(hunk_lines)
  if #groups == 0 then
    return nil
  end

  algorithm = algorithm or 'default'

  local vscode_handle = nil
  if algorithm == 'vscode' then
    vscode_handle = require('diffs.lib').load()
    if not vscode_handle then
      dbg('vscode algorithm requested but library not available, falling back to default')
    end
  end

  local diff_opts = diffopt.resolve()
  if diff_opts.algorithm then
    dbg('diffopt algorithm: %s', diff_opts.algorithm)
  end
  if diff_opts.linematch then
    dbg('diffopt linematch: %d', diff_opts.linematch)
  end

  if vscode_handle and diff_opts.ignore_whitespace and not warned_vscode_whitespace then
    warned_vscode_whitespace = true
    notify(
      'the vscode intra-line algorithm ignores only leading/trailing whitespace; '
        .. 'internal whitespace differences are still highlighted. Set '
        .. 'highlights.intra.algorithm = "default" for full whitespace handling.',
      vim.log.levels.WARN
    )
  end

  ---@type diffs.CharSpan[]
  local all_add = {}
  ---@type diffs.CharSpan[]
  local all_del = {}

  dbg(
    'intra: %d change groups, algorithm=%s, vscode=%s',
    #groups,
    algorithm,
    vscode_handle and 'yes' or 'no'
  )

  for gi, group in ipairs(groups) do
    dbg('group %d: %d del lines, %d add lines', gi, #group.del_lines, #group.add_lines)
    local ds, as
    if vscode_handle then
      ds, as = diff_group_vscode(group, vscode_handle, diff_opts)
    else
      ds, as = diff_group_native(group, diff_opts)
    end
    dbg('group %d result: %d del spans, %d add spans', gi, #ds, #as)
    for _, s in ipairs(ds) do
      dbg('  del span: line=%d col=%d..%d', s.line, s.col_start, s.col_end)
    end
    for _, s in ipairs(as) do
      dbg('  add span: line=%d col=%d..%d', s.line, s.col_start, s.col_end)
    end
    vim.list_extend(all_del, ds)
    vim.list_extend(all_add, as)
  end

  if #all_add == 0 and #all_del == 0 then
    return nil
  end

  return { add_spans = all_add, del_spans = all_del }
end

--- Normalize a line for whitespace-insensitive comparison, following the active
--- 'diffopt' flags: iwhiteall drops all whitespace, iwhite collapses runs and
--- trims, iwhiteeol trims only trailing whitespace. iblank has no per-line
--- counterpart and is not handled here (matching drop_whitespace_spans).
---@param line string
---@param diff_opts diffs.DiffOpts
---@return string
local function normalize_ws(line, diff_opts)
  if diff_opts.ignore_whitespace then
    return (line:gsub('%s+', ''))
  end
  if diff_opts.ignore_whitespace_change then
    return (line:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', ''))
  end
  if diff_opts.ignore_whitespace_change_at_eol then
    return (line:gsub('%s+$', ''))
  end
  return line
end

--- Classify which hunk lines are whitespace-only changes under the active
--- 'diffopt' whitespace flags. Returns a set keyed by the 1-based hunk line
--- index (matching `hunk.lines`). A `+`/`-` line is flagged only when it is
--- reliably paired with a counterpart that is equal once whitespace is
--- normalized; unpaired additions/deletions are never flagged. Returns an empty
--- table immediately when no whitespace flag is active.
---@param hunk_lines string[]
---@return table<integer, boolean>
function M.whitespace_only_lines(hunk_lines)
  local diff_opts = diffopt.resolve()
  if
    not (
      diff_opts.ignore_whitespace
      or diff_opts.ignore_whitespace_change
      or diff_opts.ignore_whitespace_change_at_eol
    )
  then
    return {}
  end

  ---@type table<integer, boolean>
  local result = {}
  for _, group in ipairs(M.extract_change_groups(hunk_lines)) do
    for _, pr in ipairs(pair_group_lines(group, diff_opts)) do
      if normalize_ws(pr.del.text, diff_opts) == normalize_ws(pr.add.text, diff_opts) then
        result[pr.del.idx] = true
        result[pr.add.idx] = true
      end
    end
  end
  return result
end

---@return boolean
function M.has_vscode()
  return require('diffs.lib').has_lib()
end

return M
