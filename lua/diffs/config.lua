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
---@field treesitter diffs.TreesitterConfig
---@field vim diffs.VimConfig|false
---@field intra diffs.IntraConfig|false

---@class diffs.ConflictKeymaps
---@field ours string|false
---@field theirs string|false
---@field both string|false
---@field none string|false
---@field next string|false
---@field prev string|false

---@class diffs.ConflictConfig
---@field enabled? boolean Deprecated.
---@field keymaps diffs.ConflictKeymaps|false

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
---@field conflict diffs.ConflictConfig|false

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
  conflict = {
    keymaps = false,
  },
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
      local types = key == 'treesitter' and 'table' or { 'boolean', 'table' }
      vim.validate(path, value, types, true)
      if type(value) == 'table' then
        vim.validate(path .. '.enabled', value.enabled, 'boolean', true)
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

  vim.validate('conflict', opts.conflict, function(v)
    return v == nil or type(v) == 'boolean' or type(v) == 'table'
  end, 'boolean or table')
  if type(opts.conflict) == 'table' then
    vim.validate('conflict.enabled', opts.conflict.enabled, 'boolean', true)
    vim.validate('conflict.keymaps', opts.conflict.keymaps, function(v)
      return v == nil or v == false or type(v) == 'table'
    end, 'table or false')

    if type(opts.conflict.keymaps) == 'table' then
      local keymap_validator = function(v)
        return v == nil or v == false or type(v) == 'string'
      end
      for _, key in ipairs({ 'ours', 'theirs', 'both', 'none', 'next', 'prev' }) do
        vim.validate(
          'conflict.keymaps.' .. key,
          opts.conflict.keymaps[key],
          keymap_validator,
          'string or false'
        )
      end
    end
  end

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
  if opts.highlights and type(opts.highlights.intra) == 'boolean' then
    vim.notify_once(
      '[diffs]: Boolean highlights.intra is deprecated. Support ends on November 30, 2026. '
        .. 'See :help diffs.nvim-diffopt.',
      vim.log.levels.WARN
    )
  end
  if opts.highlights and opts.highlights.context ~= nil then
    vim.notify_once(
      '[diffs]: highlights.context was removed and is ignored. Remove it from the configuration.',
      vim.log.levels.WARN
    )
  end
  local result = vim.tbl_deep_extend('force', DEFAULTS, opts)
  for _, key in ipairs({ 'treesitter', 'vim', 'intra' }) do
    local value = result.highlights[key]
    if type(value) == 'table' and value.enabled ~= nil then
      local migration = key == 'treesitter'
          and 'The enabled field is ignored. Tree-sitter highlighting is always enabled. Remove enabled.'
        or key == 'intra' and 'Remove enabled and use diffopt. See :help diffs.nvim-diffopt.'
        or 'Use highlights.vim = false to disable Vim syntax. Otherwise remove enabled.'
      vim.notify_once(
        '[diffs]: highlights.'
          .. key
          .. '.enabled is deprecated. Support ends on November 30, 2026. '
          .. migration,
        vim.log.levels.WARN
      )
      if key ~= 'treesitter' and value.enabled == false then
        result.highlights[key] = false
      else
        value.enabled = nil
      end
    end
  end
  if type(result.conflict) == 'table' and result.conflict.enabled ~= nil then
    vim.notify_once(
      '[diffs]: conflict.enabled is deprecated. Support ends on November 30, 2026. '
        .. 'Use conflict = false to disable conflict handling. Otherwise remove enabled.',
      vim.log.levels.WARN
    )
    if result.conflict.enabled == false then
      result.conflict = false
    else
      result.conflict.enabled = nil
    end
  end
  if result.conflict == true then
    result.conflict = vim.deepcopy(DEFAULTS.conflict)
  end
  for _, key in ipairs({ 'vim', 'intra' }) do
    if result.highlights[key] == true then
      result.highlights[key] = vim.deepcopy(DEFAULTS.highlights[key])
    end
  end
  return result
end

return M
