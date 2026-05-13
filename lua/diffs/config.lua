local M = {}

---@class diffs.TreesitterConfig
---@field enabled boolean
---@field max_lines integer

---@class diffs.VimConfig
---@field enabled boolean
---@field max_lines integer

---@class diffs.IntraConfig
---@field enabled boolean
---@field algorithm string
---@field max_lines integer

---@class diffs.ContextConfig
---@field enabled boolean
---@field lines integer

---@class diffs.HighlightPriorities
---@field clear integer
---@field syntax integer
---@field line_bg integer
---@field char_bg integer

---@class diffs.ViewConfig
---@field prefix boolean

---@class diffs.Highlights
---@field background boolean
---@field blend_alpha? number
---@field overrides? table<string, table>
---@field warn_max_lines boolean
---@field context diffs.ContextConfig
---@field treesitter diffs.TreesitterConfig
---@field vim diffs.VimConfig
---@field intra diffs.IntraConfig

---@class diffs.HunkHighlights: diffs.Highlights
---@field priorities diffs.HighlightPriorities

---@class diffs.ConflictKeymaps
---@field ours string|false
---@field theirs string|false
---@field both string|false
---@field none string|false
---@field next string|false
---@field prev string|false

---@alias diffs.ConflictKeymapName 'ours' | 'theirs' | 'both' | 'none' | 'next' | 'prev'

---@class diffs.ConflictConfig
---@field enabled boolean
---@field disable_diagnostics boolean
---@field show_virtual_text boolean
---@field format_virtual_text? fun(side: string, keymap: string|false): string?
---@field show_actions boolean
---@field keymaps diffs.ConflictKeymaps|false

---@class diffs.IntegrationsConfig
---@field fugitive boolean
---@field neogit boolean
---@field neojj boolean
---@field gitsigns boolean
---@field committia boolean
---@field telescope boolean

---@class diffs.Config
---@field debug boolean|string
---@field view diffs.ViewConfig
---@field extra_filetypes string[]
---@field highlights diffs.Highlights
---@field integrations diffs.IntegrationsConfig
---@field conflict diffs.ConflictConfig

---@type diffs.Config
local DEFAULTS = {
  debug = false,
  view = {
    prefix = true,
  },
  extra_filetypes = {},
  highlights = {
    background = true,
    warn_max_lines = true,
    context = {
      enabled = true,
      lines = 25,
    },
    treesitter = {
      enabled = true,
      max_lines = 500,
    },
    vim = {
      enabled = true,
      max_lines = 200,
    },
    intra = {
      enabled = true,
      algorithm = 'default',
      max_lines = 500,
    },
  },
  integrations = {
    fugitive = false,
    neogit = false,
    neojj = false,
    gitsigns = false,
    committia = false,
    telescope = false,
  },
  conflict = {
    enabled = true,
    disable_diagnostics = true,
    show_virtual_text = true,
    show_actions = false,
    keymaps = false,
  },
}

local integration_keys = { 'fugitive', 'neogit', 'neojj', 'gitsigns', 'committia', 'telescope' }

---@type diffs.HighlightPriorities
local HIGHLIGHT_PRIORITIES = {
  clear = 198,
  syntax = 199,
  line_bg = 200,
  char_bg = 201,
}

---@param path string
---@param replacement? string
local function reject_removed_key(path, replacement)
  local message = 'diffs: ' .. path .. ' has been removed'
  if replacement then
    message = message .. '; use ' .. replacement
  end
  error(message)
end

---@param opts table
local function reject_removed_config(opts)
  if opts.hide_prefix ~= nil then
    reject_removed_key('hide_prefix', 'view.prefix')
  end
  if type(opts.highlights) == 'table' then
    if opts.highlights.gutter ~= nil then
      reject_removed_key('highlights.gutter')
    end
    if opts.highlights.priorities ~= nil then
      reject_removed_key('highlights.priorities')
    end
  end
  if type(opts.conflict) == 'table' and opts.conflict.priority ~= nil then
    reject_removed_key('conflict.priority')
  end
end

---@param opts table
---@return string[]
function M.compute_filetypes(opts)
  local fts = { 'git', 'gitcommit' }
  local intg = opts.integrations or {}
  if intg.fugitive == true then
    table.insert(fts, 'fugitive')
  end
  if intg.neogit == true then
    table.insert(fts, 'NeogitStatus')
    table.insert(fts, 'NeogitCommitView')
    table.insert(fts, 'NeogitDiffView')
  end
  if intg.neojj == true then
    table.insert(fts, 'NeojjStatus')
    table.insert(fts, 'NeojjCommitView')
    table.insert(fts, 'NeojjDiffView')
  end
  if type(opts.extra_filetypes) == 'table' then
    for _, ft in ipairs(opts.extra_filetypes) do
      table.insert(fts, ft)
    end
  end
  return fts
end

---@param highlights diffs.Highlights
---@return diffs.HunkHighlights
function M.with_internal_highlight_priorities(highlights)
  local result = vim.deepcopy(highlights or {})
  result.priorities = vim.deepcopy(HIGHLIGHT_PRIORITIES)
  return result
end

---@param opts table
function M.validate(opts)
  reject_removed_config(opts)
  vim.validate('debug', opts.debug, function(v)
    return v == nil or type(v) == 'boolean' or type(v) == 'string'
  end, 'boolean or string (file path)')
  vim.validate('view', opts.view, 'table', true)
  if opts.view then
    vim.validate('view.prefix', opts.view.prefix, 'boolean', true)
  end
  vim.validate('integrations', opts.integrations, 'table', true)
  local integrations = opts.integrations or {}
  for _, key in ipairs(integration_keys) do
    vim.validate('integrations.' .. key, integrations[key], 'boolean', true)
  end
  vim.validate('extra_filetypes', opts.extra_filetypes, 'table', true)
  vim.validate('highlights', opts.highlights, 'table', true)

  if opts.highlights then
    vim.validate('highlights.background', opts.highlights.background, 'boolean', true)
    vim.validate('highlights.blend_alpha', opts.highlights.blend_alpha, 'number', true)
    vim.validate('highlights.overrides', opts.highlights.overrides, 'table', true)
    vim.validate('highlights.warn_max_lines', opts.highlights.warn_max_lines, 'boolean', true)
    vim.validate('highlights.context', opts.highlights.context, 'table', true)
    vim.validate('highlights.treesitter', opts.highlights.treesitter, 'table', true)
    vim.validate('highlights.vim', opts.highlights.vim, 'table', true)
    vim.validate('highlights.intra', opts.highlights.intra, 'table', true)

    if opts.highlights.context then
      vim.validate('highlights.context.enabled', opts.highlights.context.enabled, 'boolean', true)
      vim.validate('highlights.context.lines', opts.highlights.context.lines, 'number', true)
    end

    if opts.highlights.treesitter then
      vim.validate(
        'highlights.treesitter.enabled',
        opts.highlights.treesitter.enabled,
        'boolean',
        true
      )
      vim.validate(
        'highlights.treesitter.max_lines',
        opts.highlights.treesitter.max_lines,
        'number',
        true
      )
    end

    if opts.highlights.vim then
      vim.validate('highlights.vim.enabled', opts.highlights.vim.enabled, 'boolean', true)
      vim.validate('highlights.vim.max_lines', opts.highlights.vim.max_lines, 'number', true)
    end

    if opts.highlights.intra then
      vim.validate('highlights.intra.enabled', opts.highlights.intra.enabled, 'boolean', true)
      vim.validate('highlights.intra.algorithm', opts.highlights.intra.algorithm, function(v)
        return v == nil or v == 'default' or v == 'vscode'
      end, "'default' or 'vscode'")
      vim.validate('highlights.intra.max_lines', opts.highlights.intra.max_lines, 'number', true)
    end
  end

  if opts.conflict then
    vim.validate('conflict.enabled', opts.conflict.enabled, 'boolean', true)
    vim.validate('conflict.disable_diagnostics', opts.conflict.disable_diagnostics, 'boolean', true)
    vim.validate('conflict.show_virtual_text', opts.conflict.show_virtual_text, 'boolean', true)
    vim.validate(
      'conflict.format_virtual_text',
      opts.conflict.format_virtual_text,
      'function',
      true
    )
    vim.validate('conflict.show_actions', opts.conflict.show_actions, 'boolean', true)
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
    and opts.highlights.context
    and opts.highlights.context.lines
    and opts.highlights.context.lines < 0
  then
    error('diffs: highlights.context.lines must be >= 0')
  end
  if
    opts.highlights
    and opts.highlights.treesitter
    and opts.highlights.treesitter.max_lines
    and opts.highlights.treesitter.max_lines < 1
  then
    error('diffs: highlights.treesitter.max_lines must be >= 1')
  end
  if
    opts.highlights
    and opts.highlights.vim
    and opts.highlights.vim.max_lines
    and opts.highlights.vim.max_lines < 1
  then
    error('diffs: highlights.vim.max_lines must be >= 1')
  end
  if
    opts.highlights
    and opts.highlights.intra
    and opts.highlights.intra.max_lines
    and opts.highlights.intra.max_lines < 1
  then
    error('diffs: highlights.intra.max_lines must be >= 1')
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
  opts = opts or {}
  M.validate(opts)
  return vim.tbl_deep_extend('force', DEFAULTS, opts)
end

return M
