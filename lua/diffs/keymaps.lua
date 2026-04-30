local M = {}

---@param config diffs.ConflictConfig
---@param key diffs.ConflictKeymapName
---@return string|false
function M.get_conflict_keymap(config, key)
  local keymaps = config.keymaps
  if keymaps == false then
    return false
  end
  return keymaps[key] or false
end

---@param registry table<integer, string[]>
---@param bufnr integer
function M.clear_buffer_keymaps(registry, bufnr)
  local keymaps = registry[bufnr]
  if not keymaps then
    return
  end
  for _, keymap in ipairs(keymaps) do
    pcall(vim.keymap.del, 'n', keymap, { buffer = bufnr })
  end
  registry[bufnr] = nil
end

---@param registry table<integer, string[]>
---@param bufnr integer
---@param maps [string|false, string][]
function M.set_buffer_keymaps(registry, bufnr, maps)
  M.clear_buffer_keymaps(registry, bufnr)

  local installed = {}
  for _, map in ipairs(maps) do
    if map[1] then
      vim.keymap.set('n', map[1], map[2], { buffer = bufnr })
      installed[#installed + 1] = map[1]
    end
  end
  if #installed > 0 then
    registry[bufnr] = installed
  end
end

return M
