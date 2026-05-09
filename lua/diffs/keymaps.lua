local M = {}

---@class diffs.BufferKeymap
---@field rhs string?
---@field callback function?

---@param bufnr integer
---@param lhs string
---@return table?
local function get_buffer_keymap(bufnr, lhs)
  for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
    if keymap.lhs == lhs then
      return keymap
    end
  end
end

---@param keymap table
---@return diffs.BufferKeymap
local function keymap_identity(keymap)
  if keymap.callback then
    return { callback = keymap.callback }
  end
  return { rhs = keymap.rhs or '' }
end

---@param keymap table?
---@param identity diffs.BufferKeymap?
---@return boolean
local function keymap_matches(keymap, identity)
  if not keymap or not identity then
    return false
  end
  if identity.callback then
    return keymap.callback == identity.callback
  end
  return (keymap.rhs or '') == identity.rhs
end

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

---@param registry table<integer, table<string, diffs.BufferKeymap>>
---@param bufnr integer
function M.clear_buffer_keymaps(registry, bufnr)
  local registered = registry[bufnr]
  if not registered then
    return
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    registry[bufnr] = nil
    return
  end
  for lhs, identity in pairs(registered) do
    local current = get_buffer_keymap(bufnr, lhs)
    if keymap_matches(current, identity) then
      pcall(vim.keymap.del, 'n', lhs, { buffer = bufnr })
    end
  end
  registry[bufnr] = nil
end

---@param registry table<integer, table<string, diffs.BufferKeymap>>
---@param bufnr integer
---@param maps [string|false, string|function][]
function M.set_buffer_keymaps(registry, bufnr, maps)
  M.clear_buffer_keymaps(registry, bufnr)

  local installed = {}
  for _, map in ipairs(maps) do
    local lhs = map[1]
    if type(lhs) == 'string' then
      local current = get_buffer_keymap(bufnr, lhs)
      if not current or keymap_matches(current, installed[lhs]) then
        vim.keymap.set('n', lhs, map[2], { buffer = bufnr })
        local installed_keymap = get_buffer_keymap(bufnr, lhs)
        if installed_keymap then
          installed[lhs] = keymap_identity(installed_keymap)
        end
      end
    end
  end
  if next(installed) then
    registry[bufnr] = installed
  end
end

return M
