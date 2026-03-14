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

---@class diffs.ConflictConfig
---@field enabled boolean
---@field disable_diagnostics boolean
---@field show_virtual_text boolean
---@field format_virtual_text? fun(side: string, keymap: string|false): string?
---@field show_actions boolean
---@field priority integer
---@field keymaps diffs.ConflictKeymaps

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

---@class diffs
---@field attach fun(bufnr?: integer)
---@field refresh fun(bufnr?: integer)
local M = {}

local highlight = require('diffs.highlight')
local log = require('diffs.log')
local parser = require('diffs.parser')

local ns = vim.api.nvim_create_namespace('diffs')

---@param hex integer
---@param bg_hex integer
---@param alpha number
---@return integer
local function blend_color(hex, bg_hex, alpha)
  ---@diagnostic disable: undefined-global
  local r = bit.band(bit.rshift(hex, 16), 0xFF)
  local g = bit.band(bit.rshift(hex, 8), 0xFF)
  local b = bit.band(hex, 0xFF)

  local bg_r = bit.band(bit.rshift(bg_hex, 16), 0xFF)
  local bg_g = bit.band(bit.rshift(bg_hex, 8), 0xFF)
  local bg_b = bit.band(bg_hex, 0xFF)

  local blend_r = math.floor(r * alpha + bg_r * (1 - alpha))
  local blend_g = math.floor(g * alpha + bg_g * (1 - alpha))
  local blend_b = math.floor(b * alpha + bg_b * (1 - alpha))

  return bit.bor(bit.lshift(blend_r, 16), bit.lshift(blend_g, 8), blend_b)
  ---@diagnostic enable: undefined-global
end

---@param name string
---@return table
local function resolve_hl(name)
  local hl = vim.api.nvim_get_hl(0, { name = name })
  while hl.link do
    hl = vim.api.nvim_get_hl(0, { name = hl.link })
  end
  return hl
end

---@type diffs.Config
local default_config = {
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
    keymaps = {
      ours = 'doo',
      theirs = 'dot',
      both = 'dob',
      none = 'don',
      next = ']c',
      prev = '[c',
    },
  },
}

---@type diffs.Config
local config = vim.deepcopy(default_config)

local initialized = false
local hl_retry_pending = false

---@diagnostic disable-next-line: missing-fields
local fast_hl_opts = {} ---@type diffs.HunkOpts

---@type table<integer, boolean>
local attached_buffers = {}

---@type table<integer, boolean>
local ft_retry_pending = {}

---@type table<integer, boolean>
local diff_windows = {}

---@class diffs.HunkCacheEntry
---@field hunks diffs.Hunk[]
---@field tick integer
---@field highlighted table<integer, true>
---@field pending_clear boolean
---@field warned_max_lines boolean
---@field line_count integer
---@field byte_count integer

---@type table<integer, diffs.HunkCacheEntry>
local hunk_cache = {}

---@param bufnr integer
---@return boolean
function M.is_fugitive_buffer(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):match('^fugitive://') ~= nil
end

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

local dbg = log.dbg

---@param bufnr integer
local function invalidate_cache(bufnr)
  local entry = hunk_cache[bufnr]
  if entry then
    entry.tick = -1
    entry.pending_clear = true
  end
end

---@param a diffs.Hunk
---@param b diffs.Hunk
---@return boolean
local function hunks_eq(a, b)
  local n = #a.lines
  if n ~= #b.lines or a.filename ~= b.filename then
    return false
  end
  if a.lines[1] ~= b.lines[1] then
    return false
  end
  if n > 1 and a.lines[n] ~= b.lines[n] then
    return false
  end
  if n > 2 then
    local mid = math.floor(n / 2) + 1
    if a.lines[mid] ~= b.lines[mid] then
      return false
    end
  end
  return true
end

---@param old_entry diffs.HunkCacheEntry
---@param new_hunks diffs.Hunk[]
---@return table<integer, true>?
local function carry_forward_highlighted(old_entry, new_hunks)
  local old_hunks = old_entry.hunks
  local old_hl = old_entry.highlighted
  local old_n = #old_hunks
  local new_n = #new_hunks
  local highlighted = {}

  local prefix_len = 0
  local limit = math.min(old_n, new_n)
  for i = 1, limit do
    if not hunks_eq(old_hunks[i], new_hunks[i]) then
      break
    end
    if old_hl[i] then
      highlighted[i] = true
    end
    prefix_len = i
  end

  local suffix_len = 0
  local max_suffix = limit - prefix_len
  for j = 0, max_suffix - 1 do
    local old_idx = old_n - j
    local new_idx = new_n - j
    if not hunks_eq(old_hunks[old_idx], new_hunks[new_idx]) then
      break
    end
    if old_hl[old_idx] then
      highlighted[new_idx] = true
    end
    suffix_len = j + 1
  end

  dbg(
    'carry_forward: %d prefix + %d suffix of %d old -> %d new hunks',
    prefix_len,
    suffix_len,
    old_n,
    new_n
  )
  if next(highlighted) == nil then
    return nil
  end
  return highlighted
end

---@param path string
---@return string[]?
local function read_file_lines(path)
  if vim.fn.isdirectory(path) == 1 then
    return nil
  end
  local f = io.open(path, 'r')
  if not f then
    return nil
  end
  local lines = {}
  for line in f:lines() do
    lines[#lines + 1] = line
  end
  f:close()
  return lines
end

---@param hunks diffs.Hunk[]
---@param max_lines integer
local function compute_hunk_context(hunks, max_lines)
  ---@type table<string, string[]|false>
  local file_cache = {}

  for _, hunk in ipairs(hunks) do
    if not hunk.repo_root or not hunk.filename or not hunk.file_new_start then
      goto continue
    end

    local path = vim.fs.joinpath(hunk.repo_root, hunk.filename)
    local file_lines = file_cache[path]
    if file_lines == nil then
      file_lines = read_file_lines(path) or false
      file_cache[path] = file_lines
    end
    if not file_lines then
      goto continue
    end

    local new_start = hunk.file_new_start
    local new_count = hunk.file_new_count or 0
    local total = #file_lines

    local before_start = math.max(1, new_start - max_lines)
    if before_start < new_start then
      local before = {}
      for i = before_start, new_start - 1 do
        before[#before + 1] = file_lines[i]
      end
      hunk.context_before = before
    end

    local after_start = new_start + new_count
    local after_end = math.min(total, after_start + max_lines - 1)
    if after_start <= total then
      local after = {}
      for i = after_start, after_end do
        after[#after + 1] = file_lines[i]
      end
      hunk.context_after = after
    end

    ::continue::
  end
end

---@param bufnr integer
local function ensure_cache(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = hunk_cache[bufnr]
  if entry and entry.tick == tick then
    return
  end
  if entry and not entry.pending_clear then
    local lc = vim.api.nvim_buf_line_count(bufnr)
    local bc = vim.api.nvim_buf_get_offset(bufnr, lc)
    if lc == entry.line_count and bc == entry.byte_count then
      entry.tick = tick
      entry.pending_clear = true
      dbg('content unchanged in buffer %d (tick %d), skipping reparse', bufnr, tick)
      return
    end
  end
  local hunks = parser.parse_buffer(bufnr)
  local lc = vim.api.nvim_buf_line_count(bufnr)
  local bc = vim.api.nvim_buf_get_offset(bufnr, lc)
  dbg('parsed %d hunks in buffer %d (tick %d)', #hunks, bufnr, tick)
  if config.highlights.context.enabled then
    compute_hunk_context(hunks, config.highlights.context.lines)
  end
  local carried = entry and not entry.pending_clear and carry_forward_highlighted(entry, hunks)
  hunk_cache[bufnr] = {
    hunks = hunks,
    tick = tick,
    highlighted = carried or {},
    pending_clear = not carried,
    warned_max_lines = false,
    line_count = lc,
    byte_count = bc,
  }

  local has_nil_ft = false
  for _, hunk in ipairs(hunks) do
    if not has_nil_ft and not hunk.ft and hunk.filename then
      has_nil_ft = true
    end
  end
  if has_nil_ft and vim.fn.did_filetype() ~= 0 and not ft_retry_pending[bufnr] then
    ft_retry_pending[bufnr] = true
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) and hunk_cache[bufnr] then
        dbg('retrying filetype detection for buffer %d (was blocked by did_filetype)', bufnr)
        invalidate_cache(bufnr)
        vim.cmd('redraw!')
      end
      ft_retry_pending[bufnr] = nil
    end)
  end
end

---@param hunks diffs.Hunk[]
---@param toprow integer
---@param botrow integer
---@return integer first
---@return integer last
local function find_visible_hunks(hunks, toprow, botrow)
  local n = #hunks
  if n == 0 then
    return 0, 0
  end

  local lo, hi = 1, n + 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local h = hunks[mid]
    local bottom = h.start_line - 1 + #h.lines - 1
    if bottom < toprow then
      lo = mid + 1
    else
      hi = mid
    end
  end

  if lo > n then
    return 0, 0
  end

  local first = lo
  local h = hunks[first]
  local top = (h.header_start_line and (h.header_start_line - 1)) or (h.start_line - 1)
  if top >= botrow then
    return 0, 0
  end

  local last = first
  for i = first + 1, n do
    h = hunks[i]
    top = (h.header_start_line and (h.header_start_line - 1)) or (h.start_line - 1)
    if top >= botrow then
      break
    end
    last = i
  end

  return first, last
end

local function compute_highlight_groups(is_default)
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
  local diff_add = vim.api.nvim_get_hl(0, { name = 'DiffAdd' })
  local diff_delete = vim.api.nvim_get_hl(0, { name = 'DiffDelete' })
  local diff_added = resolve_hl('diffAdded')
  local diff_removed = resolve_hl('diffRemoved')

  local dark = vim.o.background ~= 'light'
  local transparent = not normal.bg
  local bg = normal.bg or (dark and 0x1a1a1a or 0xf0f0f0)
  local add_bg = diff_add.bg or (dark and 0x1a3a1a or 0xd0ffd0)
  local del_bg = diff_delete.bg or (dark and 0x3a1a1a or 0xffd0d0)
  local add_fg = diff_added.fg or diff_add.fg or (dark and 0x80d080 or 0x206020)
  local del_fg = diff_removed.fg or diff_delete.fg or (dark and 0xd08080 or 0x802020)

  if transparent and not hl_retry_pending then
    hl_retry_pending = true
    vim.schedule(function()
      compute_highlight_groups(false)
      for bufnr, _ in pairs(attached_buffers) do
        invalidate_cache(bufnr)
      end
    end)
  end

  local dflt = is_default or false
  local normal_fg = normal.fg or (dark and 0xcccccc or 0x333333)

  local alpha = config.highlights.blend_alpha or 0.6
  local blended_add = blend_color(add_bg, bg, alpha)
  local blended_del = blend_color(del_bg, bg, alpha)
  local blended_add_text = add_bg
  local blended_del_text = del_bg

  local clear_hl = { default = dflt, fg = normal_fg }
  if not transparent then
    clear_hl.bg = bg
  end
  vim.api.nvim_set_hl(0, 'DiffsClear', clear_hl)
  vim.api.nvim_set_hl(0, 'DiffsAdd', { default = dflt, bg = blended_add })
  vim.api.nvim_set_hl(0, 'DiffsDelete', { default = dflt, bg = blended_del })
  vim.api.nvim_set_hl(0, 'DiffsAddNr', { default = dflt, fg = add_fg, bg = blended_add })
  vim.api.nvim_set_hl(0, 'DiffsDeleteNr', { default = dflt, fg = del_fg, bg = blended_del })
  vim.api.nvim_set_hl(0, 'DiffsAddText', { default = dflt, bg = blended_add_text })
  vim.api.nvim_set_hl(0, 'DiffsDeleteText', { default = dflt, bg = blended_del_text })

  dbg(
    'highlight groups: Normal.bg=%s DiffAdd.bg=#%06x diffAdded.fg=#%06x',
    normal.bg and string.format('#%06x', normal.bg) or 'NONE',
    add_bg,
    add_fg
  )
  dbg(
    'DiffsAdd.bg=#%06x DiffsAddText.bg=#%06x DiffsAddNr.fg=#%06x',
    blended_add,
    blended_add_text,
    add_fg
  )
  dbg('DiffsDelete.bg=#%06x DiffsDeleteText.bg=#%06x', blended_del, blended_del_text)

  local diff_change = resolve_hl('DiffChange')
  local diff_text = resolve_hl('DiffText')

  vim.api.nvim_set_hl(0, 'DiffsDiffAdd', { default = dflt, bg = diff_add.bg })
  vim.api.nvim_set_hl(
    0,
    'DiffsDiffDelete',
    { default = dflt, fg = diff_delete.fg, bg = diff_delete.bg }
  )
  vim.api.nvim_set_hl(0, 'DiffsDiffChange', { default = dflt, bg = diff_change.bg })
  vim.api.nvim_set_hl(0, 'DiffsDiffText', { default = dflt, bg = diff_text.bg })

  local change_bg = diff_change.bg or 0x3a3a4a
  local text_bg = diff_text.bg or 0x4a4a5a
  local change_fg = diff_change.fg or diff_text.fg or 0x80a0c0

  local base_alpha = math.max(alpha - 0.1, 0.0)
  local blended_ours = blend_color(add_bg, bg, alpha)
  local blended_theirs = blend_color(change_bg, bg, alpha)
  local blended_base = blend_color(text_bg, bg, base_alpha)
  local blended_ours_nr = add_fg
  local blended_theirs_nr = change_fg
  local blended_base_nr = change_fg

  vim.api.nvim_set_hl(0, 'DiffsConflictOurs', { default = dflt, bg = blended_ours })
  vim.api.nvim_set_hl(0, 'DiffsConflictTheirs', { default = dflt, bg = blended_theirs })
  vim.api.nvim_set_hl(0, 'DiffsConflictBase', { default = dflt, bg = blended_base })
  vim.api.nvim_set_hl(0, 'DiffsConflictMarker', { default = dflt, fg = 0x808080, bold = true })
  vim.api.nvim_set_hl(0, 'DiffsConflictActions', { default = dflt, fg = 0x808080 })
  vim.api.nvim_set_hl(
    0,
    'DiffsConflictOursNr',
    { default = dflt, fg = blended_ours_nr, bg = blended_ours }
  )
  vim.api.nvim_set_hl(
    0,
    'DiffsConflictTheirsNr',
    { default = dflt, fg = blended_theirs_nr, bg = blended_theirs }
  )
  vim.api.nvim_set_hl(
    0,
    'DiffsConflictBaseNr',
    { default = dflt, fg = blended_base_nr, bg = blended_base }
  )

  if config.highlights.overrides then
    for group, hl in pairs(config.highlights.overrides) do
      vim.api.nvim_set_hl(0, group, hl)
    end
  end
end

local integration_keys = { 'fugitive', 'neogit', 'neojj', 'gitsigns', 'committia', 'telescope' }

local function migrate_integrations(opts)
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

local function init()
  if initialized then
    return
  end
  initialized = true

  local opts = vim.g.diffs or {}

  migrate_integrations(opts)

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

  vim.validate('debug', opts.debug, function(v)
    return v == nil or type(v) == 'boolean' or type(v) == 'string'
  end, 'boolean or string (file path)')
  vim.validate('hide_prefix', opts.hide_prefix, 'boolean', true)
  vim.validate('integrations', opts.integrations, 'table', true)
  local integration_validator = function(v)
    return v == nil or v == false or type(v) == 'table'
  end
  for _, key in ipairs(integration_keys) do
    vim.validate('integrations.' .. key, intg[key], integration_validator, 'table or false')
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

  if type(intg.fugitive) == 'table' then
    ---@type diffs.FugitiveConfig
    local fug = intg.fugitive
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
    vim.validate('conflict.keymaps', opts.conflict.keymaps, 'table', true)

    if opts.conflict.keymaps then
      local keymap_validator = function(v)
        return v == false or type(v) == 'string'
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

  config = vim.tbl_deep_extend('force', default_config, opts)
  log.set_enabled(config.debug)

  fast_hl_opts = {
    hide_prefix = config.hide_prefix,
    highlights = vim.tbl_deep_extend('force', config.highlights, {
      treesitter = { enabled = false },
    }),
    defer_vim_syntax = true,
  }

  compute_highlight_groups(true)

  vim.api.nvim_create_autocmd('ColorScheme', {
    callback = function()
      hl_retry_pending = false
      compute_highlight_groups(false)
      for bufnr, _ in pairs(attached_buffers) do
        invalidate_cache(bufnr)
      end
    end,
  })

  vim.api.nvim_set_decoration_provider(ns, {
    on_buf = function(_, bufnr)
      if not attached_buffers[bufnr] then
        return false
      end
      local t0 = config.debug and vim.uv.hrtime() or nil
      ensure_cache(bufnr)
      local entry = hunk_cache[bufnr]
      if entry and entry.pending_clear then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        entry.highlighted = {}
        entry.pending_clear = false
      end
      if t0 then
        dbg('on_buf %d: %.2fms', bufnr, (vim.uv.hrtime() - t0) / 1e6)
      end
    end,
    on_win = function(_, _, bufnr, toprow, botrow)
      if not attached_buffers[bufnr] then
        return false
      end
      local entry = hunk_cache[bufnr]
      if not entry then
        return
      end
      local first, last = find_visible_hunks(entry.hunks, toprow, botrow)
      if first == 0 then
        return
      end
      local t0 = config.debug and vim.uv.hrtime() or nil
      local deferred_syntax = {}
      local skipped_count = 0
      local count = 0
      for i = first, last do
        if not entry.highlighted[i] then
          local hunk = entry.hunks[i]
          local clear_start = hunk.start_line - 1
          local clear_end = hunk.start_line + #hunk.lines
          if hunk.header_start_line then
            clear_start = hunk.header_start_line - 1
          end
          vim.api.nvim_buf_clear_namespace(bufnr, ns, clear_start, clear_end)
          highlight.highlight_hunk(bufnr, ns, hunk, fast_hl_opts)
          entry.highlighted[i] = true
          count = count + 1
          if hunk._skipped_max_lines then
            skipped_count = skipped_count + 1
          end
          local has_syntax = hunk.lang and config.highlights.treesitter.enabled
          local needs_vim = not hunk.lang and hunk.ft and config.highlights.vim.enabled
          if has_syntax or needs_vim then
            table.insert(deferred_syntax, hunk)
          end
        end
      end
      if skipped_count > 0 and not entry.warned_max_lines and config.highlights.warn_max_lines then
        entry.warned_max_lines = true
        local n = skipped_count
        vim.schedule(function()
          vim.notify(
            (
              '[diffs.nvim]: Syntax highlighting skipped for %d hunk(s) — too large.'
              .. ' See :h diffs-max-lines to resolve or suppress this warning.'
            ):format(n),
            vim.log.levels.WARN
          )
        end)
      end
      if #deferred_syntax > 0 then
        local tick = entry.tick
        dbg('deferred syntax scheduled: %d hunks tick=%d', #deferred_syntax, tick)
        vim.schedule(function()
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end
          local cur = hunk_cache[bufnr]
          if not cur or cur.tick ~= tick then
            dbg(
              'deferred syntax stale: cur.tick=%s captured=%d',
              cur and tostring(cur.tick) or 'nil',
              tick
            )
            return
          end
          local t1 = config.debug and vim.uv.hrtime() or nil
          local syntax_opts = {
            hide_prefix = config.hide_prefix,
            highlights = config.highlights,
            syntax_only = true,
          }
          for _, hunk in ipairs(deferred_syntax) do
            highlight.highlight_hunk(bufnr, ns, hunk, syntax_opts)
          end
          if t1 then
            dbg('deferred pass: %d hunks in %.2fms', #deferred_syntax, (vim.uv.hrtime() - t1) / 1e6)
          end
        end)
      end
      if t0 and count > 0 then
        dbg(
          'on_win %d: %d hunks [%d..%d] in %.2fms (viewport %d-%d)',
          bufnr,
          count,
          first,
          last,
          (vim.uv.hrtime() - t0) / 1e6,
          toprow,
          botrow
        )
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    callback = function(args)
      local win = tonumber(args.match)
      if win and diff_windows[win] then
        diff_windows[win] = nil
      end
    end,
  })
end

---@param bufnr? integer
function M.attach(bufnr)
  init()
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if attached_buffers[bufnr] then
    return
  end
  attached_buffers[bufnr] = true

  local neogit_augroup = nil
  if config.integrations.neogit and vim.bo[bufnr].filetype:match('^Neogit') then
    vim.b[bufnr].neogit_disable_hunk_highlight = true
    neogit_augroup = vim.api.nvim_create_augroup('diffs_neogit_' .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd('User', {
      pattern = 'NeogitDiffLoaded',
      group = neogit_augroup,
      callback = function()
        if vim.api.nvim_buf_is_valid(bufnr) and attached_buffers[bufnr] then
          M.refresh(bufnr)
        end
      end,
    })
  end

  local neojj_augroup = nil
  if config.integrations.neojj and vim.bo[bufnr].filetype:match('^Neojj') then
    vim.b[bufnr].neojj_disable_hunk_highlight = true
    neojj_augroup = vim.api.nvim_create_augroup('diffs_neojj_' .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd('User', {
      pattern = 'NeojjDiffLoaded',
      group = neojj_augroup,
      callback = function()
        if vim.api.nvim_buf_is_valid(bufnr) and attached_buffers[bufnr] then
          M.refresh(bufnr)
        end
      end,
    })
  end

  dbg('attaching to buffer %d', bufnr)

  ensure_cache(bufnr)

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      attached_buffers[bufnr] = nil
      hunk_cache[bufnr] = nil
      ft_retry_pending[bufnr] = nil
      if neogit_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, neogit_augroup)
      end
      if neojj_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, neojj_augroup)
      end
    end,
  })
end

---@param bufnr? integer
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  invalidate_cache(bufnr)
end

local DIFF_WINHIGHLIGHT = table.concat({
  'DiffAdd:DiffsDiffAdd',
  'DiffDelete:DiffsDiffDelete',
  'DiffChange:DiffsDiffChange',
  'DiffText:DiffsDiffText',
}, ',')

function M.attach_diff()
  init()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local wins = vim.api.nvim_tabpage_list_wins(tabpage)

  local diff_wins = {}

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) and vim.wo[win].diff then
      table.insert(diff_wins, win)
    end
  end

  if #diff_wins == 0 then
    return
  end

  for _, win in ipairs(diff_wins) do
    vim.api.nvim_set_option_value('winhighlight', DIFF_WINHIGHLIGHT, { win = win })
    diff_windows[win] = true
    dbg('applied diff winhighlight to window %d', win)
  end
end

function M.detach_diff()
  for win, _ in pairs(diff_windows) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_option_value('winhighlight', '', { win = win })
    end
    diff_windows[win] = nil
  end
end

---@return diffs.FugitiveConfig|false
function M.get_fugitive_config()
  init()
  return config.integrations.fugitive
end

---@return diffs.NeojjConfig|false
function M.get_neojj_config()
  init()
  return config.integrations.neojj
end

---@return diffs.CommittiaConfig|false
function M.get_committia_config()
  init()
  return config.integrations.committia
end

---@return diffs.TelescopeConfig|false
function M.get_telescope_config()
  init()
  return config.integrations.telescope
end

---@return diffs.ConflictConfig
function M.get_conflict_config()
  init()
  return config.conflict
end

---@return diffs.HunkOpts
function M.get_highlight_opts()
  init()
  return { hide_prefix = config.hide_prefix, highlights = config.highlights }
end

local function process_pending_clear(bufnr)
  local entry = hunk_cache[bufnr]
  if entry and entry.pending_clear then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    entry.highlighted = {}
    entry.pending_clear = false
  end
end

M._test = {
  find_visible_hunks = find_visible_hunks,
  hunk_cache = hunk_cache,
  ensure_cache = ensure_cache,
  invalidate_cache = invalidate_cache,
  hunks_eq = hunks_eq,
  process_pending_clear = process_pending_clear,
  ft_retry_pending = ft_retry_pending,
  compute_hunk_context = compute_hunk_context,
  compute_highlight_groups = compute_highlight_groups,
  get_hl_retry_pending = function()
    return hl_retry_pending
  end,
  set_hl_retry_pending = function(v)
    hl_retry_pending = v
  end,
  get_config = function()
    return config
  end,
}

return M
