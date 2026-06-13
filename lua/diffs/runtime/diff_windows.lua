local log = require('diffs.log')

local M = {}

local WINHIGHLIGHT = table.concat({
  'DiffAdd:DiffsDiffAdd',
  'DiffDelete:DiffsDiffDelete',
  'DiffChange:DiffsDiffChange',
  'DiffText:DiffsDiffText',
}, ',')

local CONFLICT_WINHIGHLIGHT = table.concat({
  'DiffAdd:DiffsDiffOff',
  'DiffDelete:DiffsDiffOff',
  'DiffChange:DiffsDiffOff',
  'DiffText:DiffsDiffOff',
}, ',')

---@param win integer
---@return boolean
local function is_split_pane(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return pcall(vim.api.nvim_buf_get_var, buf, 'diffs_split_side')
end

---@param buf integer
---@return boolean
local function has_conflict_markers(buf)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:match('^<<<<<<<') then
      return true
    end
  end
  return false
end

---@param diff_windows table<integer, boolean>
function M.attach(diff_windows)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tabpage)

  local diff_wins = {}

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff and not is_split_pane(win) then
      table.insert(diff_wins, win)
    end
  end

  if #diff_wins == 0 then
    return
  end

  for _, win in ipairs(diff_wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    local winhighlight = has_conflict_markers(buf) and CONFLICT_WINHIGHLIGHT or WINHIGHLIGHT
    vim.api.nvim_set_option_value('winhighlight', winhighlight, { win = win })
    diff_windows[win] = true
    log.dbg('applied diff winhighlight to window %d', win)
  end
end

---@param diff_windows table<integer, boolean>
function M.detach(diff_windows)
  for win, _ in pairs(diff_windows) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_option_value('winhighlight', '', { win = win })
    end
    diff_windows[win] = nil
  end
end

---@param diff_windows table<integer, boolean>
---@param win integer?
function M.forget(diff_windows, win)
  if win then
    diff_windows[win] = nil
  end
end

return M
