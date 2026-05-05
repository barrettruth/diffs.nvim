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

---@class diffs.PrioritiesConfig
---@field clear integer
---@field syntax integer
---@field line_bg integer
---@field char_bg integer

---@class diffs.Highlights
---@field background boolean
---@field gutter boolean
---@field blend_alpha? number
---@field overrides? table<string, table>
---@field warn_max_lines boolean
---@field context diffs.ContextConfig
---@field treesitter diffs.TreesitterConfig
---@field vim diffs.VimConfig
---@field intra diffs.IntraConfig
---@field priorities diffs.PrioritiesConfig

---@class diffs.FugitiveConfig
---@field horizontal string|false
---@field vertical string|false

---@class diffs.NeogitConfig

---@class diffs.NeojjConfig

---@class diffs.GitsignsConfig

---@class diffs.CommittiaConfig

---@class diffs.TelescopeConfig

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
---@field priority integer
---@field keymaps diffs.ConflictKeymaps|false

---@class diffs.IntegrationsConfig
---@field fugitive diffs.FugitiveConfig|false
---@field neogit diffs.NeogitConfig|false
---@field neojj diffs.NeojjConfig|false
---@field gitsigns diffs.GitsignsConfig|false
---@field committia diffs.CommittiaConfig|false
---@field telescope diffs.TelescopeConfig|false

---@class diffs.Config
---@field debug boolean|string
---@field hide_prefix boolean
---@field extra_filetypes string[]
---@field highlights diffs.Highlights
---@field integrations diffs.IntegrationsConfig
---@field fugitive? diffs.FugitiveConfig|false deprecated: use integrations.fugitive
---@field neogit? diffs.NeogitConfig|false deprecated: use integrations.neogit
---@field neojj? diffs.NeojjConfig|false deprecated: use integrations.neojj
---@field gitsigns? diffs.GitsignsConfig|false deprecated: use integrations.gitsigns
---@field committia? diffs.CommittiaConfig|false deprecated: use integrations.committia
---@field telescope? diffs.TelescopeConfig|false deprecated: use integrations.telescope
---@field conflict diffs.ConflictConfig

---@type diffs.Config
local DEFAULTS = {
  debug = false,
  hide_prefix = false,
  extra_filetypes = {},
  highlights = {
    background = true,
    gutter = true,
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
    priorities = {
      clear = 198,
      syntax = 199,
      line_bg = 200,
      char_bg = 201,
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
    priority = 200,
    keymaps = false,
  },
}

local integration_keys = { 'fugitive', 'neogit', 'neojj', 'gitsigns', 'committia', 'telescope' }

---@param opts table
---@return string[]
function M.compute_filetypes(opts)
  local fts = { 'git', 'gitcommit' }
  local intg = opts.integrations or {}
  local fug = intg.fugitive
  if fug == nil then
    fug = opts.fugitive
  end
  if fug == true or type(fug) == 'table' then
    table.insert(fts, 'fugitive')
  end
  local neo = intg.neogit
  if neo == nil then
    neo = opts.neogit
  end
  if neo == true or type(neo) == 'table' then
    table.insert(fts, 'NeogitStatus')
    table.insert(fts, 'NeogitCommitView')
    table.insert(fts, 'NeogitDiffView')
  end
  local njj = intg.neojj
  if njj == nil then
    njj = opts.neojj
  end
  if njj == true or type(njj) == 'table' then
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

---@param opts table
function M.migrate_integrations(opts)
  if opts.integrations then
    local stale = {}
    for _, key in ipairs(integration_keys) do
      if opts[key] ~= nil then
        stale[#stale + 1] = key
        opts[key] = nil
      end
    end
    if #stale > 0 then
      local old = 'vim.g.diffs.{' .. table.concat(stale, ', ') .. '}'
      local new = 'vim.g.diffs.integrations.{' .. table.concat(stale, ', ') .. '}'
      vim.notify(
        '[diffs.nvim]: ignoring ' .. old .. '; move to ' .. new .. ' or remove',
        vim.log.levels.WARN
      )
    end
    return
  end
  local has_legacy = false
  for _, key in ipairs(integration_keys) do
    if opts[key] ~= nil then
      has_legacy = true
      break
    end
  end
  if not has_legacy then
    return
  end
  vim.deprecate('vim.g.diffs.<integration>', 'vim.g.diffs.integrations.*', '0.3.2', 'diffs.nvim')
  local legacy = {}
  for _, key in ipairs(integration_keys) do
    if opts[key] ~= nil then
      legacy[key] = opts[key]
      opts[key] = nil
    end
  end
  opts.integrations = legacy
end

---@param opts table
function M.normalize_integrations(opts)
  M.migrate_integrations(opts)

  local intg = opts.integrations or {}
  local fugitive_defaults = { horizontal = 'du', vertical = 'dU' }
  if intg.fugitive == true then
    intg.fugitive = vim.deepcopy(fugitive_defaults)
  elseif type(intg.fugitive) == 'table' then
    intg.fugitive = vim.tbl_extend('keep', intg.fugitive, fugitive_defaults)
  end

  if intg.neogit == true then
    intg.neogit = {}
  end

  if intg.neojj == true then
    intg.neojj = {}
  end

  if intg.gitsigns == true then
    intg.gitsigns = {}
  end

  if intg.committia == true then
    intg.committia = {}
  end

  if intg.telescope == true then
    intg.telescope = {}
  end

  opts.integrations = intg
end

---@param opts table
function M.validate(opts)
  vim.validate('debug', opts.debug, function(v)
    return v == nil or type(v) == 'boolean' or type(v) == 'string'
  end, 'boolean or string (file path)')
  vim.validate('hide_prefix', opts.hide_prefix, 'boolean', true)
  vim.validate('integrations', opts.integrations, 'table', true)
  local integration_validator = function(v)
    return v == nil or v == false or type(v) == 'table'
  end
  for _, key in ipairs(integration_keys) do
    vim.validate(
      'integrations.' .. key,
      opts.integrations[key],
      integration_validator,
      'table or false'
    )
  end
  vim.validate('extra_filetypes', opts.extra_filetypes, 'table', true)
  vim.validate('highlights', opts.highlights, 'table', true)

  if opts.highlights then
    vim.validate('highlights.background', opts.highlights.background, 'boolean', true)
    vim.validate('highlights.gutter', opts.highlights.gutter, 'boolean', true)
    vim.validate('highlights.blend_alpha', opts.highlights.blend_alpha, 'number', true)
    vim.validate('highlights.overrides', opts.highlights.overrides, 'table', true)
    vim.validate('highlights.warn_max_lines', opts.highlights.warn_max_lines, 'boolean', true)
    vim.validate('highlights.context', opts.highlights.context, 'table', true)
    vim.validate('highlights.treesitter', opts.highlights.treesitter, 'table', true)
    vim.validate('highlights.vim', opts.highlights.vim, 'table', true)
    vim.validate('highlights.intra', opts.highlights.intra, 'table', true)
    vim.validate('highlights.priorities', opts.highlights.priorities, 'table', true)

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

    if opts.highlights.priorities then
      vim.validate('highlights.priorities.clear', opts.highlights.priorities.clear, 'number', true)
      vim.validate(
        'highlights.priorities.syntax',
        opts.highlights.priorities.syntax,
        'number',
        true
      )
      vim.validate(
        'highlights.priorities.line_bg',
        opts.highlights.priorities.line_bg,
        'number',
        true
      )
      vim.validate(
        'highlights.priorities.char_bg',
        opts.highlights.priorities.char_bg,
        'number',
        true
      )
    end
  end

  if type(opts.integrations.fugitive) == 'table' then
    ---@type diffs.FugitiveConfig
    local fug = opts.integrations.fugitive
    vim.validate('integrations.fugitive.horizontal', fug.horizontal, function(v)
      return v == nil or v == false or type(v) == 'string'
    end, 'string or false')
    vim.validate('integrations.fugitive.vertical', fug.vertical, function(v)
      return v == nil or v == false or type(v) == 'string'
    end, 'string or false')
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
    vim.validate('conflict.priority', opts.conflict.priority, 'number', true)
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
  if opts.highlights and opts.highlights.priorities then
    for _, key in ipairs({ 'clear', 'syntax', 'line_bg', 'char_bg' }) do
      local v = opts.highlights.priorities[key]
      if v and v < 0 then
        error('diffs: highlights.priorities.' .. key .. ' must be >= 0')
      end
    end
  end
  if opts.conflict and opts.conflict.priority and opts.conflict.priority < 0 then
    error('diffs: conflict.priority must be >= 0')
  end
end

---@param opts? table
---@return diffs.Config
function M.new(opts)
  opts = opts or {}
  M.normalize_integrations(opts)
  M.validate(opts)
  return vim.tbl_deep_extend('force', DEFAULTS, opts)
end

return M
