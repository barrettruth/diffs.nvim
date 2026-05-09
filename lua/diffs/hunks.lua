local M = {}

local diffspec = require('diffs.spec')

---@class diffs.GdiffHunkRange
---@field start integer
---@field count integer
---@field finish integer

---@class diffs.GdiffHunkLine
---@field lnum integer
---@field kind "header"|"add"|"delete"|"context"|"meta"
---@field text string
---@field file string?
---@field old_lnum integer?
---@field new_lnum integer?
---@field source_lnum integer?
---@field hunk_index integer

---@class diffs.GdiffHunk
---@field index integer
---@field file string?
---@field path string?
---@field old_range diffs.GdiffHunkRange
---@field new_range diffs.GdiffHunkRange
---@field buffer_range diffs.GdiffHunkRange
---@field header string
---@field diff_spec diffs.DiffSpec?
---@field edge { left: diffs.Endpoint, right: diffs.Endpoint, mutation_target: "index"|"worktree"|nil }?
---@field actionable boolean
---@field mutation_target "index"|"worktree"|nil
---@field source_lnum integer
---@field lines diffs.GdiffHunkLine[]

---@param value integer
---@return integer
local function source_lnum(value)
  return math.max(value, 1)
end

---@param start integer
---@param count integer
---@return diffs.GdiffHunkRange
local function range(start, count)
  return {
    start = start,
    count = count,
    finish = count > 0 and (start + count - 1) or start,
  }
end

---@param text string
---@return integer
local function parse_count(text)
  if text == '' then
    return 1
  end
  return tonumber(text) or 1
end

---@param line string
---@return diffs.GdiffHunkRange?, diffs.GdiffHunkRange?
local function parse_header_ranges(line)
  local old_start, old_count, new_start, new_count =
    line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
  if not old_start then
    return nil, nil
  end

  return range(tonumber(old_start) or 0, parse_count(old_count)),
    range(tonumber(new_start) or 0, parse_count(new_count))
end

---@param path string?
---@param strip_prefix? boolean
---@return string?
local function normalize_path(path, strip_prefix)
  if not path or path == '/dev/null' then
    return nil
  end
  path = path:gsub('\t.*$', '')
  local normalized = strip_prefix and path:gsub('^[ab]/', '') or path
  return normalized
end

---@param line string
---@return string?, string?
local function parse_diff_git_paths(line)
  local old_path, new_path = line:match('^diff %-%-git a/(.-) b/(.+)$')
  return normalize_path(old_path), normalize_path(new_path)
end

---@param line string
---@return string?
local function parse_old_path(line)
  return normalize_path(line:match('^%-%-%- (.+)$'), true)
end

---@param line string
---@return string?
local function parse_new_path(line)
  return normalize_path(line:match('^%+%+%+ (.+)$'), true)
end

---@param diff_spec diffs.DiffSpec?
---@return diffs.DiffSpec?, "index"|"worktree"|nil, boolean
local function normalize_spec(diff_spec)
  if not diff_spec then
    return nil, nil, false
  end
  local spec = diffspec.new(diff_spec)
  local target = diffspec.mutation_target(spec)
  return spec, target, target ~= nil
end

---@param diff_lines string[]
---@param diff_spec? diffs.DiffSpec
---@return diffs.GdiffHunk[]
function M.parse(diff_lines, diff_spec)
  local spec, target, actionable = normalize_spec(diff_spec)
  local hunks = {}
  local current_old_path = spec and spec.scope.kind == diffspec.scope_kind.file and spec.scope.path
    or nil
  local current_new_path = current_old_path
  local current_file = current_new_path or current_old_path
  local current_hunk = nil
  local old_lnum = 0
  local new_lnum = 0

  ---@param finish_lnum integer
  local function finish_hunk(finish_lnum)
    if not current_hunk then
      return
    end
    current_hunk.buffer_range.finish = finish_lnum
    current_hunk.buffer_range.count = finish_lnum - current_hunk.buffer_range.start + 1
    current_hunk = nil
  end

  ---@param hunk diffs.GdiffHunk
  ---@param line diffs.GdiffHunkLine
  local function add_line(hunk, line)
    hunk.lines[#hunk.lines + 1] = line
  end

  for lnum, line in ipairs(diff_lines) do
    if line:match('^diff %-%-git ') then
      finish_hunk(lnum - 1)
      current_old_path, current_new_path = parse_diff_git_paths(line)
      current_file = current_new_path or current_old_path
    elseif line:match('^%-%-%- ') and not current_hunk then
      current_old_path = parse_old_path(line) or current_old_path
      current_file = current_new_path or current_old_path
    elseif line:match('^%+%+%+ ') and not current_hunk then
      current_new_path = parse_new_path(line) or current_new_path
      current_file = current_new_path or current_old_path
    else
      local old_range, new_range = parse_header_ranges(line)
      if old_range and new_range then
        finish_hunk(lnum - 1)
        local index = #hunks + 1
        current_hunk = {
          index = index,
          file = current_file,
          path = current_file,
          old_range = old_range,
          new_range = new_range,
          buffer_range = range(lnum, 1),
          header = line,
          diff_spec = spec,
          edge = spec and {
            left = diffspec.endpoint(spec.left),
            right = diffspec.endpoint(spec.right),
            mutation_target = target,
          } or nil,
          actionable = actionable,
          mutation_target = target,
          source_lnum = source_lnum(new_range.start),
          lines = {},
        }
        old_lnum = old_range.start
        new_lnum = new_range.start
        add_line(current_hunk, {
          lnum = lnum,
          kind = 'header',
          text = line,
          file = current_file,
          old_lnum = old_range.start,
          new_lnum = new_range.start,
          source_lnum = source_lnum(new_range.start),
          hunk_index = index,
        })
        hunks[#hunks + 1] = current_hunk
      elseif current_hunk then
        local prefix = line:sub(1, 1)
        if prefix == '+' and not line:match('^%+%+%+') then
          add_line(current_hunk, {
            lnum = lnum,
            kind = 'add',
            text = line,
            file = current_file,
            new_lnum = new_lnum,
            source_lnum = source_lnum(new_lnum),
            hunk_index = current_hunk.index,
          })
          new_lnum = new_lnum + 1
        elseif prefix == '-' and not line:match('^%-%-%-') then
          add_line(current_hunk, {
            lnum = lnum,
            kind = 'delete',
            text = line,
            file = current_file,
            old_lnum = old_lnum,
            source_lnum = source_lnum(new_lnum),
            hunk_index = current_hunk.index,
          })
          old_lnum = old_lnum + 1
        elseif prefix == ' ' then
          add_line(current_hunk, {
            lnum = lnum,
            kind = 'context',
            text = line,
            file = current_file,
            old_lnum = old_lnum,
            new_lnum = new_lnum,
            source_lnum = source_lnum(new_lnum),
            hunk_index = current_hunk.index,
          })
          old_lnum = old_lnum + 1
          new_lnum = new_lnum + 1
        else
          add_line(current_hunk, {
            lnum = lnum,
            kind = 'meta',
            text = line,
            file = current_file,
            source_lnum = source_lnum(new_lnum),
            hunk_index = current_hunk.index,
          })
        end
      end
    end
  end

  finish_hunk(#diff_lines)

  return hunks
end

---@param hunks diffs.GdiffHunk[]?
---@param lnum integer
---@return diffs.GdiffHunk?
function M.hunk_at_line(hunks, lnum)
  for _, hunk in ipairs(hunks or {}) do
    if lnum >= hunk.buffer_range.start and lnum <= hunk.buffer_range.finish then
      return hunk
    end
  end
  return nil
end

---@param hunks diffs.GdiffHunk[]?
---@param lnum integer
---@return diffs.GdiffHunkLine?
function M.line_at(hunks, lnum)
  local hunk = M.hunk_at_line(hunks, lnum)
  if not hunk then
    return nil
  end
  for _, line in ipairs(hunk.lines) do
    if line.lnum == lnum then
      return line
    end
  end
  return nil
end

---@param hunks diffs.GdiffHunk[]?
---@param lnum integer
---@return diffs.GdiffHunk?
function M.next_hunk(hunks, lnum)
  for _, hunk in ipairs(hunks or {}) do
    if hunk.buffer_range.start > lnum then
      return hunk
    end
  end
  return nil
end

---@param hunks diffs.GdiffHunk[]?
---@param lnum integer
---@return diffs.GdiffHunk?
function M.prev_hunk(hunks, lnum)
  for i = #(hunks or {}), 1, -1 do
    local hunk = hunks[i]
    if hunk.buffer_range.start < lnum then
      return hunk
    end
  end
  return nil
end

---@param item diffs.GdiffHunk|diffs.GdiffHunkLine|nil
---@return { path: string, lnum: integer }?
function M.source_line_for(item)
  if not item then
    return nil
  end
  local path = item.file or item.path
  local lnum = item.source_lnum
  if not lnum and item.new_range then
    lnum = source_lnum(item.new_range.start)
  end
  if not path or not lnum then
    return nil
  end
  return { path = path, lnum = lnum }
end

---@param bufnr integer
---@return diffs.GdiffHunk[]
local function buffer_hunks(bufnr)
  local ok, parsed = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_hunks')
  if ok and type(parsed) == 'table' then
    return parsed
  end
  return {}
end

---@param bufnr integer
function M.goto_next(bufnr)
  local parsed = buffer_hunks(bufnr)
  if #parsed == 0 then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local next_hunk = M.next_hunk(parsed, cursor_line) or parsed[1]
  if next_hunk == parsed[1] and next_hunk.buffer_range.start <= cursor_line then
    vim.notify('[diffs.nvim]: wrapped to first hunk', vim.log.levels.INFO)
  end
  vim.api.nvim_win_set_cursor(0, { next_hunk.buffer_range.start, 0 })
end

---@param bufnr integer
function M.goto_prev(bufnr)
  local parsed = buffer_hunks(bufnr)
  if #parsed == 0 then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local prev_hunk = M.prev_hunk(parsed, cursor_line) or parsed[#parsed]
  if prev_hunk == parsed[#parsed] and prev_hunk.buffer_range.start >= cursor_line then
    vim.notify('[diffs.nvim]: wrapped to last hunk', vim.log.levels.INFO)
  end
  vim.api.nvim_win_set_cursor(0, { prev_hunk.buffer_range.start, 0 })
end

return M
