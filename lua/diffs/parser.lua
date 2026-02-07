---@class diffs.Hunk
---@field filename string
---@field ft string?
---@field lang string?
---@field start_line integer
---@field header_context string?
---@field header_context_col integer?
---@field lines string[]
---@field header_start_line integer?
---@field header_lines string[]?
---@field file_old_start integer?
---@field file_old_count integer?
---@field file_new_start integer?
---@field file_new_count integer?
---@field repo_root string?

local M = {}

local dbg = require('diffs.log').dbg

---@param filepath string
---@param n integer
---@return string[]?
local function read_first_lines(filepath, n)
  local f = io.open(filepath, 'r')
  if not f then
    return nil
  end
  local lines = {}
  for _ = 1, n do
    local line = f:read('*l')
    if not line then
      break
    end
    table.insert(lines, line)
  end
  f:close()
  return #lines > 0 and lines or nil
end

---@param filename string
---@param repo_root string?
---@return string?
local function get_ft_from_filename(filename, repo_root)
  if repo_root then
    local full_path = vim.fs.joinpath(repo_root, filename)

    local buf = vim.fn.bufnr(full_path)
    if buf ~= -1 then
      local ft = vim.api.nvim_get_option_value('filetype', { buf = buf })
      if ft and ft ~= '' then
        dbg('filetype from existing buffer %d: %s', buf, ft)
        return ft
      end
    end
  end

  local ft = vim.filetype.match({ filename = filename })
  if ft then
    dbg('filetype from filename: %s', ft)
    return ft
  end

  if repo_root then
    local full_path = vim.fs.joinpath(repo_root, filename)
    local contents = read_first_lines(full_path, 10)
    if contents then
      ft = vim.filetype.match({ filename = filename, contents = contents })
      if ft then
        dbg('filetype from file content: %s', ft)
        return ft
      end
    end
  end

  dbg('no filetype for: %s', filename)
  return nil
end

---@param ft string
---@return string?
local function get_lang_from_ft(ft)
  local lang = vim.treesitter.language.get_lang(ft)
  if lang then
    local ok = pcall(vim.treesitter.language.inspect, lang)
    if ok then
      return lang
    end
    dbg('no parser for lang: %s (ft: %s)', lang, ft)
  else
    dbg('no ts lang for filetype: %s', ft)
  end
  return nil
end

---@param bufnr integer
---@return string?
local function get_repo_root(bufnr)
  local ok, repo_root = pcall(vim.api.nvim_buf_get_var, bufnr, 'diffs_repo_root')
  if ok and repo_root then
    return repo_root
  end

  local ok2, git_dir = pcall(vim.api.nvim_buf_get_var, bufnr, 'git_dir')
  if ok2 and git_dir then
    return vim.fn.fnamemodify(git_dir, ':h')
  end

  return nil
end

---@param bufnr integer
---@return diffs.Hunk[]
function M.parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local repo_root = get_repo_root(bufnr)
  ---@type diffs.Hunk[]
  local hunks = {}

  ---@type string?
  local current_filename = nil
  ---@type string?
  local current_ft = nil
  ---@type string?
  local current_lang = nil
  ---@type integer?
  local hunk_start = nil
  ---@type string?
  local hunk_header_context = nil
  ---@type integer?
  local hunk_header_context_col = nil
  ---@type string[]
  local hunk_lines = {}
  ---@type integer?
  local hunk_count = nil
  ---@type integer?
  local header_start = nil
  ---@type string[]
  local header_lines = {}
  ---@type integer?
  local file_old_start = nil
  ---@type integer?
  local file_old_count = nil
  ---@type integer?
  local file_new_start = nil
  ---@type integer?
  local file_new_count = nil

  local function flush_hunk()
    if hunk_start and #hunk_lines > 0 then
      local hunk = {
        filename = current_filename,
        ft = current_ft,
        lang = current_lang,
        start_line = hunk_start,
        header_context = hunk_header_context,
        header_context_col = hunk_header_context_col,
        lines = hunk_lines,
        file_old_start = file_old_start,
        file_old_count = file_old_count,
        file_new_start = file_new_start,
        file_new_count = file_new_count,
        repo_root = repo_root,
      }
      if hunk_count == 1 and header_start and #header_lines > 0 then
        hunk.header_start_line = header_start
        hunk.header_lines = header_lines
      end
      table.insert(hunks, hunk)
    end
    hunk_start = nil
    hunk_header_context = nil
    hunk_header_context_col = nil
    hunk_lines = {}
    file_old_start = nil
    file_old_count = nil
    file_new_start = nil
    file_new_count = nil
  end

  for i, line in ipairs(lines) do
    local filename = line:match('^[MADRC%?!]%s+(.+)$') or line:match('^diff %-%-git a/.+ b/(.+)$')
    if filename then
      flush_hunk()
      current_filename = filename
      current_ft = get_ft_from_filename(filename, repo_root)
      current_lang = current_ft and get_lang_from_ft(current_ft) or nil
      if current_lang then
        dbg('file: %s -> lang: %s', filename, current_lang)
      elseif current_ft then
        dbg('file: %s -> ft: %s (no ts parser)', filename, current_ft)
      end
      hunk_count = 0
      header_start = i
      header_lines = {}
    elseif line:match('^@@.-@@') then
      flush_hunk()
      hunk_start = i
      local hs, hc, hs2, hc2 = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
      if hs then
        file_old_start = tonumber(hs)
        file_old_count = tonumber(hc) or 1
        file_new_start = tonumber(hs2)
        file_new_count = tonumber(hc2) or 1
      end
      local prefix, context = line:match('^(@@.-@@%s*)(.*)')
      if context and context ~= '' then
        hunk_header_context = context
        hunk_header_context_col = #prefix
      end
      if hunk_count then
        hunk_count = hunk_count + 1
      end
    elseif hunk_start then
      local prefix = line:sub(1, 1)
      if prefix == ' ' or prefix == '+' or prefix == '-' then
        table.insert(hunk_lines, line)
      elseif
        line == ''
        or line:match('^[MADRC%?!]%s+')
        or line:match('^diff ')
        or line:match('^index ')
        or line:match('^Binary ')
      then
        flush_hunk()
        current_filename = nil
        current_ft = nil
        current_lang = nil
        header_start = nil
      end
    end
    if header_start and not hunk_start then
      table.insert(header_lines, line)
    end
  end

  flush_hunk()

  return hunks
end

return M
