local M = {}

local keys = { 'fugitive', 'neogit', 'neojj', 'gitsigns', 'committia', 'telescope' }

local metadata = {
  fugitive = {
    default = false,
    filetypes = { 'fugitive' },
  },
  neogit = {
    default = false,
    filetypes = { 'NeogitStatus', 'NeogitCommitView', 'NeogitDiffView' },
    filetype_pattern = '^Neogit',
  },
  neojj = {
    default = false,
    filetypes = { 'NeojjStatus', 'NeojjCommitView', 'NeojjDiffView' },
    filetype_pattern = '^Neojj',
  },
  gitsigns = {
    default = false,
  },
  committia = {
    default = false,
  },
  telescope = {
    default = false,
  },
}

---@return string[]
function M.keys()
  return vim.deepcopy(keys)
end

---@return table<string, boolean>
function M.defaults()
  local result = {}
  for _, key in ipairs(keys) do
    result[key] = metadata[key].default
  end
  return result
end

---@param value any
---@return boolean
function M.is_enabled(value)
  return value == true
end

---@param opts table
---@return string[]
function M.filetypes(opts)
  local fts = { 'git', 'gitcommit' }
  local intg = opts.integrations or {}
  for _, key in ipairs(keys) do
    if M.is_enabled(intg[key]) then
      for _, filetype in ipairs(metadata[key].filetypes or {}) do
        table.insert(fts, filetype)
      end
    end
  end
  if type(opts.extra_filetypes) == 'table' then
    for _, ft in ipairs(opts.extra_filetypes) do
      table.insert(fts, ft)
    end
  end
  return fts
end

---@param key string
---@param filetype string
---@return boolean
function M.matches_filetype(key, filetype)
  local pattern = metadata[key] and metadata[key].filetype_pattern
  return pattern ~= nil and filetype:match(pattern) ~= nil
end

return M
