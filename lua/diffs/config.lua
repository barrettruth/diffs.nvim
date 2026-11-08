local M = {}

local integration_metadata = require('diffs.integrations')

---@class diffs.TreesitterConfig
---@field max_lines integer

---@class diffs.VimConfig
---@field max_lines integer

---@class diffs.IntraConfig
---@field algorithm string
---@field max_lines integer

---@class diffs.ViewConfig
---@field default_layout "unified"|"stacked"|"split"
---@field prefix boolean

---@class diffs.Highlights
---@field background boolean
---@field blend_alpha? number
---@field overrides? table<string, table>
---@field warn_max_lines boolean
---@field treesitter diffs.TreesitterConfig|false
---@field vim diffs.VimConfig|false
---@field intra diffs.IntraConfig|false

---@class diffs.DifftasticConfig
---@field args? string[]

---@class diffs.IntegrationsConfig
---@field fugitive? boolean
---@field neogit? boolean
---@field neojj? boolean
---@field gitsigns? boolean
---@field committia? boolean
---@field telescope? boolean
---@field difftastic? boolean|diffs.DifftasticConfig

---@class diffs.Config
---@field debug boolean|string
---@field view diffs.ViewConfig
---@field extra_filetypes string[]
---@field highlights diffs.Highlights
---@field integrations diffs.IntegrationsConfig
---@field conflict boolean

---@type diffs.Config
local DEFAULTS = {
  debug = false,
  view = {
    default_layout = 'unified',
    prefix = true,
  },
  extra_filetypes = {},
  highlights = {
    background = true,
    warn_max_lines = true,
    treesitter = {
      max_lines = 500,
    },
    vim = {
      max_lines = 200,
    },
    intra = {
      algorithm = 'default',
      max_lines = 500,
    },
  },
  integrations = {},
  conflict = true,
}

---@param opts? table
---@return string[]
function M.compute_filetypes(opts)
  return integration_metadata.filetypes(opts or {})
end

---@param opts table
function M.validate(opts)
  vim.validate('debug', opts.debug, function(v)
    return v == nil or type(v) == 'boolean' or type(v) == 'string'
  end, 'boolean or string (file path)')
  vim.validate('view', opts.view, 'table', true)
  if opts.view then
    vim.validate('view.prefix', opts.view.prefix, 'boolean', true)
  end
  vim.validate('integrations', opts.integrations, 'table', true)
  local integrations = opts.integrations or {}
  for _, key in ipairs(integration_metadata.keys()) do
    vim.validate('integrations.' .. key, integrations[key], 'boolean', true)
  end
  vim.validate('integrations.difftastic', integrations.difftastic, function(v)
    return v == nil or type(v) == 'boolean' or type(v) == 'table'
  end, 'boolean or table')
  if type(integrations.difftastic) == 'table' then
    vim.validate('integrations.difftastic.args', integrations.difftastic.args, 'table', true)
    for i, arg in ipairs(integrations.difftastic.args or {}) do
      vim.validate('integrations.difftastic.args[' .. i .. ']', arg, 'string')
    end
  end
  vim.validate('extra_filetypes', opts.extra_filetypes, 'table', true)
  vim.validate('highlights', opts.highlights, 'table', true)

  if opts.highlights then
    vim.validate('highlights.background', opts.highlights.background, 'boolean', true)
    vim.validate('highlights.blend_alpha', opts.highlights.blend_alpha, 'number', true)
    vim.validate('highlights.overrides', opts.highlights.overrides, 'table', true)
    vim.validate('highlights.warn_max_lines', opts.highlights.warn_max_lines, 'boolean', true)

    for _, key in ipairs({ 'treesitter', 'vim', 'intra' }) do
      local path = 'highlights.' .. key
      local value = opts.highlights[key]
      vim.validate(path, value, function(v)
        return v == nil or type(v) == 'boolean' or type(v) == 'table'
      end, 'boolean or table')
      if type(value) == 'table' then
        vim.validate(path .. '.max_lines', value.max_lines, 'number', true)
        if value.max_lines and value.max_lines < 1 then
          error('diffs: ' .. path .. '.max_lines must be >= 1')
        end
      end
    end

    if type(opts.highlights.intra) == 'table' then
      vim.validate('highlights.intra.algorithm', opts.highlights.intra.algorithm, function(v)
        return v == nil or v == 'default' or v == 'vscode'
      end, "'default' or 'vscode'")
    end
  end

  vim.validate('conflict', opts.conflict, 'boolean', true)

  if
    opts.highlights
    and opts.highlights.blend_alpha
    and (opts.highlights.blend_alpha < 0 or opts.highlights.blend_alpha > 1)
  then
    error('diffs: highlights.blend_alpha must be >= 0 and <= 1')
  end
end

---@param opts? table
---@return diffs.Config
function M.new(opts)
  opts = vim.tbl_extend('force', opts or {}, {
    integrations = integration_metadata.normalize(opts and opts.integrations),
  })
  M.validate(opts)
  local result = vim.tbl_deep_extend('force', DEFAULTS, opts)
  for _, key in ipairs({ 'treesitter', 'vim', 'intra' }) do
    if result.highlights[key] == true then
      result.highlights[key] = vim.deepcopy(DEFAULTS.highlights[key])
    end
  end
  return result
end

return M
