local M = {}

local diffspec = require('diffs.spec')
local notify = require('diffs.log').notify

---@class diffs.DiffHunkRange
---@field start integer
---@field count integer
---@field finish integer

---@class diffs.DiffHunkLine
---@field lnum integer
---@field kind "header"|"add"|"delete"|"context"|"meta"
---@field text string
---@field file string?
---@field old_lnum integer?
---@field new_lnum integer?
---@field source_lnum integer?
---@field hunk_index integer

---@class diffs.DiffHunk
---@field index integer
---@field file string?
---@field path string?
---@field old_range diffs.DiffHunkRange
---@field new_range diffs.DiffHunkRange
---@field buffer_range diffs.DiffHunkRange
---@field file_header_range diffs.DiffHunkRange?
---@field file_header_lines string[]
---@field header string
---@field generated_key string?
---@field section string?
---@field section_label string?
---@field diff_spec diffs.DiffSpec?
---@field edge { left: diffs.Endpoint, right: diffs.Endpoint, mutation_target: "index"|"worktree"|nil }?
---@field can_put boolean
---@field can_obtain boolean
---@field actionable boolean
---@field mutation_target "index"|"worktree"|nil
---@field source_lnum integer
---@field lines diffs.DiffHunkLine[]

---@param value integer
---@return integer
local function source_lnum(value)
  return math.max(value, 1)
end

---@param start integer
---@param count integer
---@return diffs.DiffHunkRange
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
---@return diffs.DiffHunkRange?, diffs.DiffHunkRange?
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
  local normalized = strip_prefix and path:gsub('^%a/', '') or path
  return normalized
end

---@param line string
---@return string?, string?
local function parse_diff_git_paths(line)
  local old_path, new_path = line:match('^diff %-%-git %a/(.-) %a/(.+)$')
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

---@param line string
---@return boolean
local function is_review_section_header(line)
  return line:match('^# Branch:') ~= nil
    or line:match('^# Staged:') ~= nil
    or line:match('^# Unstaged:') ~= nil
    or line:match('^# Untracked:') ~= nil
end

---@param diff_spec diffs.DiffSpec?
---@return diffs.DiffSpec?
local function normalize_spec(diff_spec)
  if not diff_spec then
    return nil
  end
  return diffspec.new(diff_spec)
end

---@param lines string[]
---@return string[]
local function copy_lines(lines)
  local copied = {}
  for _, line in ipairs(lines) do
    copied[#copied + 1] = line
  end
  return copied
end

---@param diff_lines string[]
---@param diff_spec? diffs.DiffSpec
---@return diffs.DiffHunk[]
function M.parse(diff_lines, diff_spec)
  local spec = normalize_spec(diff_spec)
  local hunks = {}
  local current_old_path = spec and spec.scope.kind == diffspec.scope_kind.file and spec.scope.path
    or nil
  local current_new_path = current_old_path
  local current_file = current_new_path or current_old_path
  local current_hunk = nil
  local current_file_header_start = nil
  local current_file_header_lines = {}
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

  ---@param lnum integer
  ---@param line string
  local function start_file_header(lnum, line)
    current_file_header_start = lnum
    current_file_header_lines = { line }
  end

  ---@param lnum integer
  ---@param line string
  local function add_file_header_line(lnum, line)
    if not current_file_header_start then
      current_file_header_start = lnum
    end
    current_file_header_lines[#current_file_header_lines + 1] = line
  end

  ---@param hunk diffs.DiffHunk
  ---@param line diffs.DiffHunkLine
  local function add_line(hunk, line)
    hunk.lines[#hunk.lines + 1] = line
  end

  for lnum, line in ipairs(diff_lines) do
    if is_review_section_header(line) then
      finish_hunk(lnum - 1)
      current_old_path = spec and spec.scope.kind == diffspec.scope_kind.file and spec.scope.path
        or nil
      current_new_path = current_old_path
      current_file = current_new_path or current_old_path
      current_hunk = nil
      current_file_header_start = nil
      current_file_header_lines = {}
      old_lnum = 0
      new_lnum = 0
    elseif line:match('^diff %-%-git ') then
      finish_hunk(lnum - 1)
      current_old_path, current_new_path = parse_diff_git_paths(line)
      current_file = current_new_path or current_old_path
      start_file_header(lnum, line)
    elseif line:match('^%-%-%- ') and not current_hunk then
      current_old_path = parse_old_path(line) or current_old_path
      current_file = current_new_path or current_old_path
      add_file_header_line(lnum, line)
    elseif line:match('^%+%+%+ ') and not current_hunk then
      current_new_path = parse_new_path(line) or current_new_path
      current_file = current_new_path or current_old_path
      add_file_header_line(lnum, line)
    else
      local old_range, new_range = parse_header_ranges(line)
      if old_range and new_range then
        finish_hunk(lnum - 1)
        local index = #hunks + 1
        local file_header_lines = copy_lines(current_file_header_lines)
        current_hunk = {
          index = index,
          file = current_file,
          path = current_file,
          old_range = old_range,
          new_range = new_range,
          buffer_range = range(lnum, 1),
          file_header_range = current_file_header_start
              and range(current_file_header_start, #file_header_lines)
            or nil,
          file_header_lines = file_header_lines,
          header = line,
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
      elseif current_file_header_start then
        add_file_header_line(lnum, line)
      end
    end
  end

  finish_hunk(#diff_lines)

  return M.decorate_actionability(hunks, spec)
end

---@param hunk diffs.DiffHunk
---@param spec diffs.DiffSpec?
---@param target "index"|"worktree"|nil
---@param can_put boolean
---@param can_obtain boolean
local function decorate_hunk_actionability(hunk, spec, target, can_put, can_obtain)
  hunk.diff_spec = spec
  hunk.edge = spec
      and {
        left = diffspec.endpoint(spec.left),
        right = diffspec.endpoint(spec.right),
        mutation_target = target,
      }
    or nil
  hunk.can_put = can_put
  hunk.can_obtain = can_obtain
  hunk.actionable = can_put or can_obtain
  hunk.mutation_target = target
end

---@param hunks diffs.DiffHunk[]
---@param diff_spec? diffs.DiffSpec
---@return diffs.DiffHunk[]
function M.decorate_actionability(hunks, diff_spec)
  local spec = normalize_spec(diff_spec)
  local target = spec and diffspec.mutation_target(spec) or nil
  local patch_actions = spec and diffspec.patch_actions(spec) or nil
  local can_put = patch_actions and patch_actions.can_put or false
  local can_obtain = patch_actions and patch_actions.can_obtain or false

  for _, hunk in ipairs(hunks or {}) do
    decorate_hunk_actionability(hunk, spec, target, can_put, can_obtain)
  end
  return hunks
end

---@param hunks diffs.DiffHunk[]?
---@param lnum integer
---@return diffs.DiffHunk?
function M.hunk_at_line(hunks, lnum)
  for _, hunk in ipairs(hunks or {}) do
    if lnum >= hunk.buffer_range.start and lnum <= hunk.buffer_range.finish then
      return hunk
    end
  end
  return nil
end

---@param hunks diffs.DiffHunk[]?
---@param lnum integer
---@return diffs.DiffHunkLine?
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

---@param hunks diffs.DiffHunk[]?
---@param lnum integer
---@return diffs.DiffHunk?
function M.next_hunk(hunks, lnum)
  for _, hunk in ipairs(hunks or {}) do
    if hunk.buffer_range.start > lnum then
      return hunk
    end
  end
  return nil
end

---@param hunks diffs.DiffHunk[]?
---@param lnum integer
---@return diffs.DiffHunk?
function M.prev_hunk(hunks, lnum)
  for i = #(hunks or {}), 1, -1 do
    local hunk = hunks[i]
    if hunk.buffer_range.start < lnum then
      return hunk
    end
  end
  return nil
end

---@param item diffs.DiffHunk|diffs.DiffHunkLine|nil
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
---@return diffs.DiffHunk[]
local function buffer_hunks(bufnr)
  local ok, parsed = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_hunks')
  if ok and type(parsed) == 'table' then
    return parsed
  end
  return {}
end

---@param bufnr integer
---@param name string
---@return any
local function get_buf_var(bufnr, name)
  local ok, value = pcall(vim.api.nvim_buf_get_var, bufnr, name)
  if ok then
    return value
  end
  return nil
end

---@param filepath string
---@return integer?
local function find_window_for_file(filepath)
  local tabpage = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_get_name(buf) == filepath then
        return win
      end
    end
  end
  return nil
end

---@param repo_root string
---@param path string
---@return string
local function resolve_worktree_path(repo_root, path)
  if path:sub(1, 1) == '/' then
    return path
  end
  return vim.fs.joinpath(repo_root, path)
end

---@param bufnr integer
---@return { path: string, lnum: integer }?, string?
function M.source_at_cursor(bufnr)
  local parsed = buffer_hunks(bufnr)
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local hunk = M.hunk_at_line(parsed, cursor_line)
  if not hunk then
    return nil, 'cursor is not on a diff hunk'
  end

  local spec = hunk.diff_spec and diffspec.new(hunk.diff_spec) or nil
  if not spec then
    return nil, 'missing diffs_spec metadata for hunk'
  end

  if spec.right.kind == diffspec.endpoint_kind.index then
    return nil, 'cannot open index-backed diff hunk as a worktree file'
  end
  if spec.right.kind ~= diffspec.endpoint_kind.worktree then
    return nil, 'cannot open read-only tree-backed diff hunk as a worktree file'
  end

  local source = M.source_line_for(M.line_at(parsed, cursor_line)) or M.source_line_for(hunk)
  if not source then
    return nil, 'could not resolve source location for hunk'
  end

  local repo_root = get_buf_var(bufnr, 'diffs_repo_root')
  if type(repo_root) ~= 'string' or repo_root == '' then
    return nil, 'cannot open source without diffs_repo_root'
  end

  return {
    path = resolve_worktree_path(repo_root, source.path),
    lnum = source.lnum,
  },
    nil
end

---@param bufnr integer
---@return boolean
function M.open_source(bufnr)
  local source, err = M.source_at_cursor(bufnr)
  if not source then
    notify(err, vim.log.levels.WARN)
    return false
  end

  local win = find_window_for_file(source.path)
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd.edit(vim.fn.fnameescape(source.path))
  end

  local line_count = vim.api.nvim_buf_line_count(0)
  local lnum = math.max(1, math.min(source.lnum, line_count))
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  return true
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
    notify('wrapped to first hunk', vim.log.levels.INFO)
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
    notify('wrapped to last hunk', vim.log.levels.INFO)
  end
  vim.api.nvim_win_set_cursor(0, { prev_hunk.buffer_range.start, 0 })
end

return M
