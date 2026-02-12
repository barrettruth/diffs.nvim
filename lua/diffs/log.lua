local M = {}

local enabled = false
local log_file = nil

---@param val boolean|string
function M.set_enabled(val)
  if type(val) == 'string' then
    enabled = true
    log_file = val
  else
    enabled = val
    log_file = nil
  end
end

---@param msg string
---@param ... any
function M.dbg(msg, ...)
  if not enabled then
    return
  end
  local formatted = '[diffs.nvim]: ' .. string.format(msg, ...)
  if log_file then
    local f = io.open(log_file, 'a')
    if f then
      f:write(string.format('%.6fs', vim.uv.hrtime() / 1e9) .. ' ' .. formatted .. '\n')
      f:close()
    end
  else
    vim.notify(formatted, vim.log.levels.DEBUG)
  end
end

return M
