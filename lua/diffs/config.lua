local M = {}

local integration_metadata = require('diffs.integrations')

---@class diffs.TreesitterConfig
---@field max_lines integer

---@class diffs.VimConfig
---@field max_lines integer

---@class diffs.IntraConfig
---@field max_lines integer

---@class diffs.ViewConfig
---@field default_layout "unified"|"stacked"|"split"
---@field prefix boolean

---@class diffs.Highlights
---@field background boolean
---@field blend_alpha? number
---@field warn_max_lines boolean
---@field treesitter diffs.TreesitterConfig
---@field vim diffs.VimConfig|false
---@field intra diffs.IntraConfig

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

---@param opts? table
---@return diffs.Config
function M.new(opts)
  opts = vim.tbl_extend('force', opts or {}, {
    integrations = integration_metadata.normalize(opts and opts.integrations),
  })
  local result = vim.tbl_deep_extend('force', DEFAULTS, opts)
  if result.highlights.vim == true then
    result.highlights.vim = vim.deepcopy(DEFAULTS.highlights.vim)
  end
  return result
end

return M
