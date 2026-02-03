local M = {}

local enabled = false

---@param val boolean
function M.set_enabled(val)
  enabled = val
end

---@param msg string
---@param ... any
function M.dbg(msg, ...)
  if not enabled then
    return
  end
  vim.notify('[diffs] ' .. string.format(msg, ...), vim.log.levels.DEBUG)
end

return M
