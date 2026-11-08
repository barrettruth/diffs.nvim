local M = {}

local keys = { 'fugitive', 'neogit', 'neojj' }

local metadata = {
  fugitive = {
    filetypes = { 'fugitive' },
  },
  neogit = {
    filetypes = { 'NeogitStatus', 'NeogitCommitView', 'NeogitDiffView' },
    filetype_pattern = '^Neogit',
  },
  neojj = {
    filetypes = { 'NeojjStatus', 'NeojjCommitView', 'NeojjDiffView' },
    filetype_pattern = '^Neojj',
  },
}

---@param values table?
---@return diffs.IntegrationsConfig
function M.normalize(values)
  local result = {}
  for key, value in pairs(values or {}) do
    if type(key) == 'number' then
      result[value] = true
    else
      result[key] = value
    end
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
  local intg = M.normalize(opts.integrations)
  for _, key in ipairs(keys) do
    if M.is_enabled(intg[key]) then
      for _, filetype in ipairs(metadata[key] and metadata[key].filetypes or {}) do
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
