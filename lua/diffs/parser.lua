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
---@field prefix_width integer
---@field quote_width integer
---@field repo_root string?

local M = {}

local dbg = require('diffs.log').dbg

---@type table<string, {ft: string?, lang: string?}>
local ft_lang_cache = {}

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
  if not ft and vim.fn.did_filetype() ~= 0 then
    dbg('retrying filetype match for %s (clearing did_filetype)', filename)
    local saved = rawget(vim.fn, 'did_filetype')
    rawset(vim.fn, 'did_filetype', function()
      return 0
    end)
    ft = vim.filetype.match({ filename = filename })
    rawset(vim.fn, 'did_filetype', saved)
  end
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

  local ok3, neogit_git_dir = pcall(vim.api.nvim_buf_get_var, bufnr, 'neogit_git_dir')
  if ok3 and neogit_git_dir then
    return vim.fn.fnamemodify(neogit_git_dir, ':h')
  end

  local cwd = vim.fn.getcwd()
  local git = require('diffs.git')
  return git.get_repo_root(cwd .. '/.')
end

---@param bufnr integer
---@return diffs.Hunk[]
function M.parse_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local repo_root = get_repo_root(bufnr)

  local quote_prefix = nil
  local quote_width = 0
  for _, l in ipairs(lines) do
    local qp = l:match('^(>+ )diff %-%-') or l:match('^(>+ )@@ %-')
    if qp then
      quote_prefix = qp
      quote_width = #qp
      break
    end
  end

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
  ---@type integer
  local hunk_prefix_width = 1
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
  ---@type integer?
  local old_remaining = nil
  ---@type integer?
  local new_remaining = nil
  local current_quote_width = 0

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
        prefix_width = hunk_prefix_width,
        quote_width = current_quote_width,
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
    old_remaining = nil
    new_remaining = nil
  end

  for i, line in ipairs(lines) do
    local logical = line
    if quote_prefix then
      if line:sub(1, quote_width) == quote_prefix then
        logical = line:sub(quote_width + 1)
      elseif line:match('^>+$') then
        logical = ''
      end
    end

    local diff_git_file = logical:match('^diff %-%-git a/.+ b/(.+)$')
      or logical:match('^diff %-%-combined (.+)$')
      or logical:match('^diff %-%-cc (.+)$')
    local neogit_file = logical:match('^modified%s+(.+)$')
      or (not logical:match('^new file mode') and logical:match('^new file%s+(.+)$'))
      or (not logical:match('^deleted file mode') and logical:match('^deleted%s+(.+)$'))
      or logical:match('^renamed%s+(.+)$')
      or logical:match('^copied%s+(.+)$')
    local bare_file = not hunk_start and logical:match('^([^%s]+%.[^%s]+)$')
    local filename = logical:match('^[MADRCU%?!]%s+(.+)$')
      or diff_git_file
      or neogit_file
      or bare_file
    if filename then
      flush_hunk()
      current_filename = filename
      current_quote_width = (logical ~= line) and quote_width or 0
      local cache_key = (repo_root or '') .. '\0' .. filename
      local cached = ft_lang_cache[cache_key]
      if cached then
        current_ft = cached.ft
        current_lang = cached.lang
      else
        current_ft = get_ft_from_filename(filename, repo_root)
        current_lang = current_ft and get_lang_from_ft(current_ft) or nil
        if current_ft or vim.fn.did_filetype() == 0 then
          ft_lang_cache[cache_key] = { ft = current_ft, lang = current_lang }
        end
      end
      if current_lang then
        dbg('file: %s -> lang: %s', filename, current_lang)
      elseif current_ft then
        dbg('file: %s -> ft: %s (no ts parser)', filename, current_ft)
      end
      hunk_count = 0
      hunk_prefix_width = 1
      header_start = i
      header_lines = {}
    elseif logical:match('^@@+') then
      flush_hunk()
      hunk_start = i
      local at_prefix = logical:match('^(@@+)')
      hunk_prefix_width = #at_prefix - 1
      if #at_prefix == 2 then
        local hs, hc, hs2, hc2 = logical:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
        if hs then
          file_old_start = tonumber(hs)
          file_old_count = tonumber(hc) or 1
          file_new_start = tonumber(hs2)
          file_new_count = tonumber(hc2) or 1
          old_remaining = file_old_count
          new_remaining = file_new_count
        end
      else
        local hs, hc = logical:match('%-(%d+),?(%d*)')
        if hs then
          file_old_start = tonumber(hs)
          file_old_count = tonumber(hc) or 1
          old_remaining = file_old_count
        end
        local hs2, hc2 = logical:match('%+(%d+),?(%d*) @@')
        if hs2 then
          file_new_start = tonumber(hs2)
          file_new_count = tonumber(hc2) or 1
          new_remaining = file_new_count
        end
      end
      local at_end, context = logical:match('^(@@+.-@@+%s*)(.*)')
      if context and context ~= '' then
        hunk_header_context = context
        hunk_header_context_col = #at_end + current_quote_width
      end
      if hunk_count then
        hunk_count = hunk_count + 1
      end
    elseif hunk_start then
      local prefix = logical:sub(1, 1)
      if prefix == ' ' or prefix == '+' or prefix == '-' then
        table.insert(hunk_lines, logical)
        if old_remaining and (prefix == ' ' or prefix == '-') then
          old_remaining = old_remaining - 1
        end
        if new_remaining and (prefix == ' ' or prefix == '+') then
          new_remaining = new_remaining - 1
        end
      elseif
        logical == ''
        and old_remaining
        and old_remaining > 0
        and new_remaining
        and new_remaining > 0
      then
        table.insert(hunk_lines, string.rep(' ', hunk_prefix_width))
        old_remaining = old_remaining - 1
        new_remaining = new_remaining - 1
      elseif
        logical == ''
        or logical:match('^[MADRC%?!]%s+')
        or logical:match('^diff ')
        or logical:match('^index ')
        or logical:match('^Binary ')
      then
        flush_hunk()
        current_filename = nil
        current_ft = nil
        current_lang = nil
        header_start = nil
      end
    end
    if header_start and not hunk_start then
      table.insert(header_lines, logical)
    end
  end

  flush_hunk()

  return hunks
end

M._test = {
  ft_lang_cache = ft_lang_cache,
}

return M
