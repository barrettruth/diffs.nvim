local log = require('diffs.log')

local M = {}

local WINHIGHLIGHT = table.concat({
  'DiffAdd:DiffsDiffAdd',
  'DiffDelete:DiffsDiffDelete',
  'DiffChange:DiffsDiffChange',
  'DiffText:DiffsDiffText',
}, ',')

---@param diff_windows table<integer, boolean>
function M.attach(diff_windows)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tabpage)

  local diff_wins = {}

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      table.insert(diff_wins, win)
    end
  end

  if #diff_wins == 0 then
    return
  end

  for _, win in ipairs(diff_wins) do
    vim.api.nvim_set_option_value('winhighlight', WINHIGHLIGHT, { win = win })
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
