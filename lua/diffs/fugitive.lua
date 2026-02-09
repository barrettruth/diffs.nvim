local M = {}

local commands = require('diffs.commands')
local git = require('diffs.git')
local dbg = require('diffs.log').dbg

---@alias diffs.FugitiveSection 'staged' | 'unstaged' | 'untracked' | nil

---@param bufnr integer
---@param lnum integer
---@return diffs.FugitiveSection
function M.get_section_at_line(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, lnum, false)

  for i = #lines, 1, -1 do
    local line = lines[i]
    if line:match('^Staged ') then
      return 'staged'
    elseif line:match('^Unstaged ') then
      return 'unstaged'
    elseif line:match('^Untracked ') then
      return 'untracked'
    end
  end

  return nil
end

---@param s string
---@return string
local function unquote(s)
  if s:sub(1, 1) ~= '"' then
    return s
  end
  local inner = s:sub(2, -2)
  local result = {}
  local i = 1
  while i <= #inner do
    if inner:sub(i, i) == '\\' and i < #inner then
      local next_char = inner:sub(i + 1, i + 1)
      if next_char == 'n' then
        table.insert(result, '\n')
        i = i + 2
      elseif next_char == 't' then
        table.insert(result, '\t')
        i = i + 2
      elseif next_char == '"' then
        table.insert(result, '"')
        i = i + 2
      elseif next_char == '\\' then
        table.insert(result, '\\')
        i = i + 2
      elseif next_char:match('%d') then
        local oct = inner:match('^(%d%d%d)', i + 1)
        if oct then
          table.insert(result, string.char(tonumber(oct, 8)))
          i = i + 4
        else
          table.insert(result, next_char)
          i = i + 2
        end
      else
        table.insert(result, next_char)
        i = i + 2
      end
    else
      table.insert(result, inner:sub(i, i))
      i = i + 1
    end
  end
  return table.concat(result)
end

---@param line string
---@return string?, string?, string?
local function parse_file_line(line)
  local old, new = line:match('^R%d*%s+(.-)%s+->%s+(.+)$')
  if old and new then
    return unquote(vim.trim(new)), unquote(vim.trim(old)), 'R'
  end

  local status, filename = line:match('^([MADRCU?])[MADRCU%s]*%s+(.+)$')
  if status and filename then
    return unquote(vim.trim(filename)), nil, status
  end

  return nil, nil, nil
end

---@param line string
---@return diffs.FugitiveSection?
local function parse_section_header(line)
  if line:match('^Staged %(%d') then
    return 'staged'
  elseif line:match('^Unstaged %(%d') then
    return 'unstaged'
  elseif line:match('^Untracked %(%d') then
    return 'untracked'
  end
  return nil
end

---@param bufnr integer
---@param lnum integer
---@return string?, diffs.FugitiveSection, boolean, string?, string?
function M.get_file_at_line(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local current_line = lines[lnum]

  if not current_line then
    return nil, nil, false, nil, nil
  end

  local section_header = parse_section_header(current_line)
  if section_header then
    return nil, section_header, true, nil, nil
  end

  local filename, old_filename, status = parse_file_line(current_line)
  if filename then
    local section = M.get_section_at_line(bufnr, lnum)
    return filename, section, false, old_filename, status
  end

  local prefix = current_line:sub(1, 1)
  if prefix == '+' or prefix == '-' or prefix == ' ' then
    for i = lnum - 1, 1, -1 do
      local prev_line = lines[i]
      filename, old_filename, status = parse_file_line(prev_line)
      if filename then
        local section = M.get_section_at_line(bufnr, i)
        return filename, section, false, old_filename, status
      end
      if prev_line:match('^%w+ %(') or prev_line == '' then
        break
      end
    end
  end

  return nil, nil, false, nil, nil
end

---@class diffs.HunkPosition
---@field hunk_header string
---@field offset integer

---@param bufnr integer
---@param lnum integer
---@return diffs.HunkPosition?
function M.get_hunk_position(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, lnum, false)
  local current = lines[lnum]

  if not current then
    return nil
  end

  local prefix = current:sub(1, 1)
  if prefix ~= '+' and prefix ~= '-' and prefix ~= ' ' then
    return nil
  end

  for i = lnum - 1, 1, -1 do
    local line = lines[i]
    if line:match('^@@.-@@') then
      return {
        hunk_header = line,
        offset = lnum - i,
      }
    end
    if line:match('^[MADRCU?!]%s') or line:match('^%w+ %(') then
      break
    end
  end

  return nil
end

---@param bufnr integer
---@return string?
local function get_repo_root_from_fugitive(bufnr)
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local fugitive_path = bufname:match('^fugitive://(.+)///')
  if fugitive_path then
    return fugitive_path
  end

  local cwd = vim.fn.getcwd()
  local root = git.get_repo_root(cwd .. '/.')
  return root
end

---@param vertical boolean
function M.diff_file_under_cursor(vertical)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  local filename, section, is_header, old_filename, status = M.get_file_at_line(bufnr, lnum)

  local repo_root = get_repo_root_from_fugitive(bufnr)
  if not repo_root then
    vim.notify('[diffs.nvim]: could not determine repository root', vim.log.levels.ERROR)
    return
  end

  if is_header then
    dbg('diff_section: %s', section or 'unknown')
    if section == 'untracked' then
      vim.notify('[diffs.nvim]: cannot diff untracked section', vim.log.levels.WARN)
      return
    end
    commands.gdiff_section(repo_root, {
      vertical = vertical,
      staged = section == 'staged',
    })
    return
  end

  if not filename then
    vim.notify('[diffs.nvim]: no file under cursor', vim.log.levels.WARN)
    return
  end

  local filepath = repo_root .. '/' .. filename
  local old_filepath = old_filename and (repo_root .. '/' .. old_filename) or nil
  local hunk_position = M.get_hunk_position(bufnr, lnum)

  dbg(
    'diff_file_under_cursor: %s (section: %s, old: %s, hunk_offset: %s)',
    filename,
    section or 'unknown',
    old_filename or 'none',
    hunk_position and tostring(hunk_position.offset) or 'none'
  )

  commands.gdiff_file(filepath, {
    vertical = vertical,
    staged = section == 'staged',
    untracked = section == 'untracked',
    unmerged = status == 'U',
    old_filepath = old_filepath,
    hunk_position = hunk_position,
  })
end

---@param bufnr integer
---@param config { horizontal: string|false, vertical: string|false }
function M.setup_keymaps(bufnr, config)
  if config.horizontal and config.horizontal ~= '' then
    vim.keymap.set('n', config.horizontal, function()
      M.diff_file_under_cursor(false)
    end, { buffer = bufnr, desc = 'Unified diff (horizontal)' })
    dbg('set keymap %s for buffer %d', config.horizontal, bufnr)
  end

  if config.vertical and config.vertical ~= '' then
    vim.keymap.set('n', config.vertical, function()
      M.diff_file_under_cursor(true)
    end, { buffer = bufnr, desc = 'Unified diff (vertical)' })
    dbg('set keymap %s for buffer %d', config.vertical, bufnr)
  end
end

return M
