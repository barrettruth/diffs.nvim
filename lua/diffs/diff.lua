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
---@return {old_start: integer, old_count: integer, new_start: integer, new_count: integer}[]
local function byte_diff(old_text, new_text)
  local ok, result = pcall(vim.diff, old_text, new_text, { result_type = 'indices' })
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

---@param old_line string
---@param new_line string
---@param del_idx integer
---@param add_idx integer
---@return diffs.CharSpan[], diffs.CharSpan[]
local function char_diff_pair(old_line, new_line, del_idx, add_idx)
  ---@type diffs.CharSpan[]
  local del_spans = {}
  ---@type diffs.CharSpan[]
  local add_spans = {}

  local old_bytes = split_bytes(old_line)
  local new_bytes = split_bytes(new_line)

  local old_text = table.concat(old_bytes, '\n') .. '\n'
  local new_text = table.concat(new_bytes, '\n') .. '\n'

  local char_hunks = byte_diff(old_text, new_text)

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

  return del_spans, add_spans
end

---@param group diffs.ChangeGroup
---@return diffs.CharSpan[], diffs.CharSpan[]
local function diff_group_native(group)
  ---@type diffs.CharSpan[]
  local all_del = {}
  ---@type diffs.CharSpan[]
  local all_add = {}

  local del_count = #group.del_lines
  local add_count = #group.add_lines

  if del_count == 1 and add_count == 1 then
    local ds, as = char_diff_pair(
      group.del_lines[1].text,
      group.add_lines[1].text,
      group.del_lines[1].idx,
      group.add_lines[1].idx
    )
    vim.list_extend(all_del, ds)
    vim.list_extend(all_add, as)
    return all_del, all_add
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

  local line_hunks = byte_diff(old_block, new_block)

  ---@type table<integer, integer>
  local old_to_new = {}
  for _, lh in ipairs(line_hunks) do
    if lh.old_count == lh.new_count then
      for k = 0, lh.old_count - 1 do
        old_to_new[lh.old_start + k] = lh.new_start + k
      end
    end
  end

  for old_i, new_i in pairs(old_to_new) do
    if group.del_lines[old_i] and group.add_lines[new_i] then
      local ds, as = char_diff_pair(
        group.del_lines[old_i].text,
        group.add_lines[new_i].text,
        group.del_lines[old_i].idx,
        group.add_lines[new_i].idx
      )
      vim.list_extend(all_del, ds)
      vim.list_extend(all_add, as)
    end
  end

  for _, lh in ipairs(line_hunks) do
    if lh.old_count ~= lh.new_count then
      local pairs_count = math.min(lh.old_count, lh.new_count)
      for k = 0, pairs_count - 1 do
        local oi = lh.old_start + k
        local ni = lh.new_start + k
        if group.del_lines[oi] and group.add_lines[ni] then
          local ds, as = char_diff_pair(
            group.del_lines[oi].text,
            group.add_lines[ni].text,
            group.del_lines[oi].idx,
            group.add_lines[ni].idx
          )
          vim.list_extend(all_del, ds)
          vim.list_extend(all_add, as)
        end
      end
    end
  end

  return all_del, all_add
end

---@param group diffs.ChangeGroup
---@param handle table
---@return diffs.CharSpan[], diffs.CharSpan[]
local function diff_group_vscode(group, handle)
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

  local opts = ffi.new('DiffsDiffOptions', {
    ignore_trim_whitespace = false,
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

  algorithm = algorithm or 'auto'

  local lib = require('diffs.lib')
  local vscode_handle = nil
  if algorithm ~= 'native' then
    vscode_handle = lib.load()
  end

  if algorithm == 'vscode' and not vscode_handle then
    dbg('vscode algorithm requested but library not available, falling back to native')
  end

  ---@type diffs.CharSpan[]
  local all_add = {}
  ---@type diffs.CharSpan[]
  local all_del = {}

  for _, group in ipairs(groups) do
    local ds, as
    if vscode_handle then
      ds, as = diff_group_vscode(group, vscode_handle)
    else
      ds, as = diff_group_native(group)
    end
    vim.list_extend(all_del, ds)
    vim.list_extend(all_add, as)
  end

  if #all_add == 0 and #all_del == 0 then
    return nil
  end

  return { add_spans = all_add, del_spans = all_del }
end

---@return boolean
function M.has_vscode()
  return require('diffs.lib').has_lib()
end

return M
