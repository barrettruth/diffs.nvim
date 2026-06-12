local M = {}

local hunk_model = require('diffs.hunks')
local log = require('diffs.log')
local runtime = require('diffs.runtime')

local dbg = log.dbg

local unified_ns = vim.api.nvim_create_namespace('diffs_difftastic_unified')
local active_var = 'diffs_difft_active'

local COMMAND = 'difft'
local TIMEOUT_MS = 5000

---@class diffs.DifftAlignment : diffs.SplitAlignment
---@field left_intra table<integer, {col_start: integer, col_end: integer}[]>
---@field right_intra table<integer, {col_start: integer, col_end: integer}[]>
---@field changed boolean

--- Mark a buffer as rendered by difftastic. Suppresses the decorator's own
--- intra step and short-circuits whitespace toggling (moot for a structural
--- diff).
---@param bufnr integer
function M.mark_active(bufnr)
  pcall(vim.api.nvim_buf_set_var, bufnr, active_var, true)
end

---@param bufnr integer
function M.clear_active(bufnr)
  pcall(vim.api.nvim_buf_del_var, bufnr, active_var)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, unified_ns, 0, -1)
end

---@param bufnr integer
---@return boolean
function M.is_active(bufnr)
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, active_var)
  return ok and value == true
end

---@return { enabled: boolean, args: string[] }
function M.resolve()
  local raw = runtime.get_difftastic_config()
  if raw == nil or raw == false then
    return { enabled = false, args = {} }
  end
  local args = {}
  if type(raw) == 'table' and type(raw.args) == 'table' then
    args = raw.args
  end
  return { enabled = true, args = args }
end

---@return boolean
function M.available()
  return M.resolve().enabled and vim.fn.executable(COMMAND) == 1
end

---@param value any
---@return any
local function nilify(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

--- Coerce a ContentLines (a list with extra non-integer metadata keys) into a
--- plain string[] that vim.fn.writefile can convert to a Vim list.
---@param lines string[]|diffs.ContentLines
---@return string[]
local function plain_lines(lines)
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = line
  end
  return out
end

---@param old_lines string[]
---@param new_lines string[]
---@param relpath string
---@return string, string, string temp dir, old path, new path
local function write_pair(old_lines, new_lines, relpath)
  local tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, 'p')
  local base = vim.fn.fnamemodify(relpath, ':t')
  if base == '' then
    base = 'file'
  end
  local old_file = tmp .. '/old_' .. base
  local new_file = tmp .. '/new_' .. base
  vim.fn.writefile(plain_lines(old_lines), old_file)
  vim.fn.writefile(plain_lines(new_lines), new_file)
  return tmp, old_file, new_file
end

--- Run difft on two file paths and return the decoded JSON, or nil + error.
--- We always force JSON output, no color, and strip-cr off (so difft's byte
--- offsets stay aligned with our exact line bytes); user `args` are appended.
---@param old_path string
---@param new_path string
---@return table?, string?
function M.run_json(old_path, new_path)
  local cfg = M.resolve()
  if not cfg.enabled then
    return nil, 'difftastic disabled'
  end

  local cmd = { COMMAND, '--display', 'json', '--color', 'never', '--strip-cr', 'off' }
  for _, arg in ipairs(cfg.args) do
    cmd[#cmd + 1] = arg
  end
  cmd[#cmd + 1] = old_path
  cmd[#cmd + 1] = new_path

  local env = vim.tbl_extend('force', vim.fn.environ(), { DFT_UNSTABLE = 'yes' })
  local ok, result = pcall(function()
    return vim.system(cmd, { text = true, env = env }):wait(TIMEOUT_MS)
  end)
  if not ok then
    return nil, 'difft invocation failed: ' .. tostring(result)
  end
  if result.code ~= 0 and result.code ~= 1 then
    return nil, 'difft exited ' .. tostring(result.code) .. ': ' .. (result.stderr or '')
  end
  if not result.stdout or result.stdout == '' then
    return nil, 'difft produced no output'
  end

  local decoded_ok, decoded = pcall(vim.json.decode, result.stdout)
  if not decoded_ok then
    return nil, 'invalid difft json: ' .. tostring(decoded)
  end
  if type(decoded) == 'table' and decoded.aligned_lines == nil and decoded[1] ~= nil then
    decoded = decoded[1]
  end
  if type(decoded) ~= 'table' then
    return nil, 'unexpected difft json shape'
  end
  if decoded.status == 'created' or decoded.status == 'deleted' then
    return nil, 'difftastic: no structural diff for ' .. decoded.status .. ' file'
  end
  if decoded.status ~= 'unchanged' and (decoded.aligned_lines == nil or decoded.chunks == nil) then
    return nil, 'unexpected difft json shape'
  end
  if type(decoded.language) == 'string' and decoded.language:match('^Text') then
    dbg('difftastic line-diff fallback: %s', decoded.language)
  end
  return decoded
end

--- Per-line change spans, keyed by 0-based line number. Robust to difft's
--- unordered chunk entries (we key by line_number, never rely on order).
---@param json table
---@return table<integer, {col_start: integer, col_end: integer}[]>, table<integer, {col_start: integer, col_end: integer}[]>
function M.span_maps(json)
  local lhs, rhs = {}, {}
  local function collect(side_map, side)
    local entry = nilify(side)
    if not entry then
      return
    end
    local line = nilify(entry.line_number)
    if line == nil then
      return
    end
    local spans = {}
    for _, change in ipairs(entry.changes or {}) do
      local s = nilify(change.start)
      local e = nilify(change['end'])
      if type(s) == 'number' and type(e) == 'number' and e > s then
        spans[#spans + 1] = { col_start = s, col_end = e }
      end
    end
    side_map[line] = spans
  end
  for _, chunk in ipairs(json.chunks or {}) do
    for _, row in ipairs(chunk) do
      collect(lhs, row.lhs)
      collect(rhs, row.rhs)
    end
  end
  return lhs, rhs
end

---@param maps table<integer, table[]>
---@return boolean
local function map_has_spans(maps)
  return next(maps) ~= nil
end

---@param lhs table?
---@param rhs table?
---@return boolean
function M.has_changes(lhs, rhs)
  return (lhs ~= nil and map_has_spans(lhs)) or (rhs ~= nil and map_has_spans(rhs))
end

---@param spans {col_start: integer, col_end: integer}[]?
---@return boolean
local function has_spans(spans)
  return spans ~= nil and #spans > 0
end

--- Build a split-compatible alignment (diffs.SplitAlignment shape) from
--- difftastic's whole-file structural alignment, plus per-row intra spans.
---@param json table
---@param old_lines string[]
---@param new_lines string[]
---@return diffs.DifftAlignment
function M.build_alignment(json, old_lines, new_lines)
  local lhs, rhs = M.span_maps(json)
  local left_lines, right_lines = {}, {}
  local left_rows, right_rows = {}, {}
  local left_intra, right_intra = {}, {}
  local anchors = {}
  local prev_changed = false
  local changed = false

  for _, pair in ipairs(json.aligned_lines or {}) do
    local l, r = nilify(pair[1]), nilify(pair[2])
    local left_content = l ~= nil and old_lines[l + 1] or nil
    local right_content = r ~= nil and new_lines[r + 1] or nil
    local left_past = l ~= nil and left_content == nil
    local right_past = r ~= nil and right_content == nil
    local both_virtual = (l == nil or left_past) and (r == nil or right_past)

    if not both_virtual then
      local left_changes = (l ~= nil and not left_past) and lhs[l] or nil
      local right_changes = (r ~= nil and not right_past) and rhs[r] or nil
      local left_filler = l == nil or left_past
      local right_filler = r == nil or right_past

      local left_kind = left_filler and 'filler'
        or (has_spans(left_changes) and 'delete' or 'context')
      local right_kind = right_filler and 'filler'
        or (has_spans(right_changes) and 'add' or 'context')

      local idx = #left_lines + 1
      left_lines[idx] = left_content or ''
      right_lines[idx] = right_content or ''
      left_rows[idx] = {
        kind = left_kind,
        old_lnum = (not left_filler) and (l + 1) or nil,
        new_lnum = (not left_filler and r ~= nil and not right_past) and (r + 1) or nil,
      }
      right_rows[idx] = {
        kind = right_kind,
        old_lnum = (not right_filler and l ~= nil and not left_past) and (l + 1) or nil,
        new_lnum = (not right_filler) and (r + 1) or nil,
      }
      if has_spans(left_changes) then
        left_intra[idx] = left_changes
      end
      if has_spans(right_changes) then
        right_intra[idx] = right_changes
      end

      local row_changed = left_kind == 'delete'
        or left_kind == 'filler'
        or right_kind == 'add'
        or right_kind == 'filler'
      if row_changed then
        changed = true
        if not prev_changed then
          anchors[#anchors + 1] = idx
        end
      end
      prev_changed = row_changed
    end
  end

  return {
    left_lines = left_lines,
    right_lines = right_lines,
    left_rows = left_rows,
    right_rows = right_rows,
    anchors = anchors,
    left_intra = left_intra,
    right_intra = right_intra,
    changed = changed,
  }
end

--- Structural alignment for the split layout, from two content arrays.
---@param old_lines string[]
---@param new_lines string[]
---@param relpath string
---@return diffs.DifftAlignment?, string?
function M.align(old_lines, new_lines, relpath)
  old_lines = plain_lines(old_lines)
  new_lines = plain_lines(new_lines)
  local tmp, old_file, new_file = write_pair(old_lines, new_lines, relpath)
  local json, err = M.run_json(old_file, new_file)
  pcall(vim.fn.delete, tmp, 'rf')
  if not json then
    dbg('difftastic align failed: %s', err or 'unknown')
    return nil, err
  end
  return M.build_alignment(json, old_lines, new_lines)
end

--- Per-line span maps for two content arrays (materialized to temp files).
---@param old_lines string[]
---@param new_lines string[]
---@param relpath string
---@return table?, table?, string?
function M.span_maps_for_content(old_lines, new_lines, relpath)
  local tmp, old_file, new_file = write_pair(old_lines, new_lines, relpath)
  local json, err = M.run_json(old_file, new_file)
  pcall(vim.fn.delete, tmp, 'rf')
  if not json then
    dbg('difftastic span maps failed: %s', err or 'unknown')
    return nil, nil, err
  end
  local lhs, rhs = M.span_maps(json)
  return lhs, rhs
end

--- Per-line span maps for two real file paths (`:Diff files` — no temp files).
---@param left_path string
---@param right_path string
---@return table?, table?, string?
function M.span_maps_for_paths(left_path, right_path)
  local json, err = M.run_json(left_path, right_path)
  if not json then
    dbg('difftastic span maps failed: %s', err or 'unknown')
    return nil, nil, err
  end
  local lhs, rhs = M.span_maps(json)
  return lhs, rhs
end

--- Paint structural intra-line spans onto a generated unified diffs:// buffer,
--- mapping difft's per-line spans onto the parsed hunk lines. Spans land in a
--- dedicated namespace; the decorator's own intra step is suppressed for the
--- buffer (diffs_difft_active). Content columns are offset past the rail and the
--- one-character diff prefix (rail_width + 1).
---@param bufnr integer
---@param lhs table<integer, table[]>
---@param rhs table<integer, table[]>
---@param diff_lines string[]
---@param spec diffs.DiffSpec?
---@param rail_width integer
---@return integer applied span count
function M.apply_unified(bufnr, lhs, rhs, diff_lines, spec, rail_width)
  local opts = runtime.get_highlight_opts()
  local intra_cfg = opts.highlights.intra
  local priority = opts.highlights.priorities.char_bg
  local base = rail_width + 1

  vim.api.nvim_buf_clear_namespace(bufnr, unified_ns, 0, -1)
  M.mark_active(bufnr)

  if not intra_cfg or not intra_cfg.enabled then
    return 0
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local applied = 0
  for _, hunk in ipairs(hunk_model.parse(diff_lines, spec)) do
    for _, line in ipairs(hunk.lines) do
      local spans, hl
      if line.kind == 'delete' and line.old_lnum then
        spans, hl = lhs[line.old_lnum - 1], 'DiffsDeleteText'
      elseif line.kind == 'add' and line.new_lnum then
        spans, hl = rhs[line.new_lnum - 1], 'DiffsAddText'
      end
      if spans and line.lnum >= 1 and line.lnum <= line_count then
        for _, span in ipairs(spans) do
          local ok = pcall(
            vim.api.nvim_buf_set_extmark,
            bufnr,
            unified_ns,
            line.lnum - 1,
            base + span.col_start,
            {
              end_col = base + span.col_end,
              hl_group = hl,
              priority = priority,
            }
          )
          if ok then
            applied = applied + 1
          end
        end
      end
    end
  end
  return applied
end

M._test = {
  nilify = nilify,
  plain_lines = plain_lines,
}

return M
