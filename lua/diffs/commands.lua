local M = {}

local git = require('diffs.git')
local dbg = require('diffs.log').dbg

---@param old_lines string[]
---@param new_lines string[]
---@param old_name string
---@param new_name string
---@return string[]
local function generate_unified_diff(old_lines, new_lines, old_name, new_name)
  local old_content = table.concat(old_lines, '\n')
  local new_content = table.concat(new_lines, '\n')

  local diff_fn = vim.text and vim.text.diff or vim.diff
  local diff_output = diff_fn(old_content, new_content, {
    result_type = 'unified',
    ctxlen = 3,
  })

  if not diff_output or diff_output == '' then
    return {}
  end

  local diff_lines = vim.split(diff_output, '\n', { plain = true })

  local result = {
    'diff --git a/' .. old_name .. ' b/' .. new_name,
    '--- a/' .. old_name,
    '+++ b/' .. new_name,
  }
  for _, line in ipairs(diff_lines) do
    table.insert(result, line)
  end

  return result
end

---@param revision? string
---@param vertical? boolean
function M.gdiff(revision, vertical)
  revision = revision or 'HEAD'

  local bufnr = vim.api.nvim_get_current_buf()
  local filepath = vim.api.nvim_buf_get_name(bufnr)

  if filepath == '' then
    vim.notify('[diffs.nvim]: cannot diff unnamed buffer', vim.log.levels.ERROR)
    return
  end

  local rel_path = git.get_relative_path(filepath)
  if not rel_path then
    vim.notify('[diffs.nvim]: not in a git repository', vim.log.levels.ERROR)
    return
  end

  local old_lines, err = git.get_file_content(revision, filepath)
  if not old_lines then
    vim.notify('[diffs.nvim]: ' .. (err or 'unknown error'), vim.log.levels.ERROR)
    return
  end

  local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local diff_lines = generate_unified_diff(old_lines, new_lines, rel_path, rel_path)

  if #diff_lines == 0 then
    vim.notify('[diffs.nvim]: no diff against ' .. revision, vim.log.levels.INFO)
    return
  end

  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = diff_buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = diff_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = diff_buf })
  vim.api.nvim_buf_set_name(diff_buf, 'diffs://' .. revision .. ':' .. rel_path)

  vim.cmd(vertical and 'vsplit' or 'split')
  vim.api.nvim_win_set_buf(0, diff_buf)

  dbg('opened diff buffer %d for %s against %s', diff_buf, rel_path, revision)

  vim.schedule(function()
    require('diffs').attach(diff_buf)
  end)
end

---@class diffs.GdiffFileOpts
---@field vertical? boolean
---@field staged? boolean
---@field untracked? boolean

---@param filepath string
---@param opts? diffs.GdiffFileOpts
function M.gdiff_file(filepath, opts)
  opts = opts or {}

  local rel_path = git.get_relative_path(filepath)
  if not rel_path then
    vim.notify('[diffs.nvim]: not in a git repository', vim.log.levels.ERROR)
    return
  end

  local old_lines, new_lines, err
  local diff_label

  if opts.untracked then
    old_lines = {}
    new_lines, err = git.get_working_content(filepath)
    if not new_lines then
      vim.notify('[diffs.nvim]: ' .. (err or 'cannot read file'), vim.log.levels.ERROR)
      return
    end
    diff_label = 'untracked'
  elseif opts.staged then
    old_lines, err = git.get_file_content('HEAD', filepath)
    if not old_lines then
      old_lines = {}
    end
    new_lines, err = git.get_index_content(filepath)
    if not new_lines then
      new_lines = {}
    end
    diff_label = 'staged'
  else
    old_lines, err = git.get_index_content(filepath)
    if not old_lines then
      old_lines, err = git.get_file_content('HEAD', filepath)
      if not old_lines then
        old_lines = {}
        diff_label = 'untracked'
      else
        diff_label = 'unstaged'
      end
    else
      diff_label = 'unstaged'
    end
    new_lines, err = git.get_working_content(filepath)
    if not new_lines then
      new_lines = {}
    end
  end

  local diff_lines = generate_unified_diff(old_lines, new_lines, rel_path, rel_path)

  if #diff_lines == 0 then
    vim.notify('[diffs.nvim]: no changes', vim.log.levels.INFO)
    return
  end

  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, diff_lines)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = diff_buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = diff_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = diff_buf })
  vim.api.nvim_buf_set_name(diff_buf, 'diffs://' .. diff_label .. ':' .. rel_path)

  vim.cmd(opts.vertical and 'vsplit' or 'split')
  vim.api.nvim_win_set_buf(0, diff_buf)

  dbg('opened diff buffer %d for %s (%s)', diff_buf, rel_path, diff_label)

  vim.schedule(function()
    require('diffs').attach(diff_buf)
  end)
end

---@class diffs.GdiffSectionOpts
---@field vertical? boolean
---@field staged? boolean

---@param repo_root string
---@param opts? diffs.GdiffSectionOpts
function M.gdiff_section(repo_root, opts)
  opts = opts or {}

  local cmd = { 'git', '-C', repo_root, 'diff', '--no-ext-diff', '--no-color' }
  if opts.staged then
    table.insert(cmd, '--cached')
  end

  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    vim.notify('[diffs.nvim]: git diff failed', vim.log.levels.ERROR)
    return
  end

  if #result == 0 then
    vim.notify('[diffs.nvim]: no changes in section', vim.log.levels.INFO)
    return
  end

  local diff_label = opts.staged and 'staged' or 'unstaged'
  local diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(diff_buf, 0, -1, false, result)
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = diff_buf })
  vim.api.nvim_set_option_value('bufhidden', 'wipe', { buf = diff_buf })
  vim.api.nvim_set_option_value('modifiable', false, { buf = diff_buf })
  vim.api.nvim_set_option_value('filetype', 'diff', { buf = diff_buf })
  vim.api.nvim_buf_set_name(diff_buf, 'diffs://' .. diff_label .. ':all')

  vim.cmd(opts.vertical and 'vsplit' or 'split')
  vim.api.nvim_win_set_buf(0, diff_buf)

  dbg('opened section diff buffer %d (%s)', diff_buf, diff_label)

  vim.schedule(function()
    require('diffs').attach(diff_buf)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command('Gdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, false)
  end, {
    nargs = '?',
    desc = 'Show unified diff against git revision (default: HEAD)',
  })

  vim.api.nvim_create_user_command('Gvdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, true)
  end, {
    nargs = '?',
    desc = 'Show unified diff against git revision in vertical split',
  })

  vim.api.nvim_create_user_command('Ghdiff', function(opts)
    M.gdiff(opts.args ~= '' and opts.args or nil, false)
  end, {
    nargs = '?',
    desc = 'Show unified diff against git revision in horizontal split',
  })
end

return M
