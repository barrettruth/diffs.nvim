local M = {}

local FILLER = ''

---@class diffs.SplitRow
---@field kind "context"|"delete"|"add"|"filler"
---@field old_lnum integer?
---@field new_lnum integer?
---@field hunk_index integer?

---@class diffs.SplitAlignment
---@field left_lines string[]
---@field right_lines string[]
---@field left_rows diffs.SplitRow[]
---@field right_rows diffs.SplitRow[]
---@field anchors integer[] buffer row (1-indexed) of each hunk's first changed line

---@param old_lines string[]
---@param new_lines string[]
---@param hunks diffs.DiffHunk[]
---@return diffs.SplitAlignment
function M.align(old_lines, new_lines, hunks)
  local left_lines, right_lines = {}, {}
  local left_rows, right_rows = {}, {}
  local anchors = {}

  local function push(lt, lr, rt, rr)
    left_lines[#left_lines + 1] = lt
    left_rows[#left_rows + 1] = lr
    right_lines[#right_lines + 1] = rt
    right_rows[#right_rows + 1] = rr
  end

  local function push_context(old_lnum, new_lnum, hunk_index)
    push(
      old_lines[old_lnum] or '',
      {
        kind = 'context',
        old_lnum = old_lnum,
        new_lnum = new_lnum,
        hunk_index = hunk_index,
      },
      new_lines[new_lnum] or '',
      {
        kind = 'context',
        old_lnum = old_lnum,
        new_lnum = new_lnum,
        hunk_index = hunk_index,
      }
    )
  end

  local function flush_change(dels, adds, hunk_index)
    if hunk_index and not anchors[hunk_index] and (#dels > 0 or #adds > 0) then
      anchors[hunk_index] = #left_lines + 1
    end
    for i = 1, math.max(#dels, #adds) do
      local d, a = dels[i], adds[i]
      push(
        d and (old_lines[d] or '') or FILLER,
        d and { kind = 'delete', old_lnum = d, hunk_index = hunk_index }
          or { kind = 'filler', hunk_index = hunk_index },
        a and (new_lines[a] or '') or FILLER,
        a and { kind = 'add', new_lnum = a, hunk_index = hunk_index }
          or { kind = 'filler', hunk_index = hunk_index }
      )
    end
  end

  local old_cursor, new_cursor = 1, 1
  for _, hunk in ipairs(hunks) do
    while old_cursor < hunk.old_range.start do
      push_context(old_cursor, new_cursor)
      old_cursor = old_cursor + 1
      new_cursor = new_cursor + 1
    end

    local dels, adds = {}, {}
    local function flush()
      if #dels > 0 or #adds > 0 then
        flush_change(dels, adds, hunk.index)
        dels, adds = {}, {}
      end
    end

    for _, line in ipairs(hunk.lines) do
      if line.kind == 'context' then
        flush()
        push_context(line.old_lnum, line.new_lnum, hunk.index)
        old_cursor = (line.old_lnum or old_cursor) + 1
        new_cursor = (line.new_lnum or new_cursor) + 1
      elseif line.kind == 'delete' then
        dels[#dels + 1] = line.old_lnum
        old_cursor = (line.old_lnum or old_cursor) + 1
      elseif line.kind == 'add' then
        adds[#adds + 1] = line.new_lnum
        new_cursor = (line.new_lnum or new_cursor) + 1
      end
    end
    flush()
  end

  while old_cursor <= #old_lines do
    push_context(old_cursor, new_cursor)
    old_cursor = old_cursor + 1
    new_cursor = new_cursor + 1
  end

  return {
    left_lines = left_lines,
    right_lines = right_lines,
    left_rows = left_rows,
    right_rows = right_rows,
    anchors = anchors,
  }
end

return M
