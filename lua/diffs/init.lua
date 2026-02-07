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

---@class diffs.Highlights
---@field background boolean
---@field gutter boolean
---@field treesitter diffs.TreesitterConfig
---@field vim diffs.VimConfig
---@field intra diffs.IntraConfig

---@class diffs.FugitiveConfig
---@field horizontal string|false
---@field vertical string|false

---@class diffs.Config
---@field debug boolean
---@field debounce_ms integer
---@field hide_prefix boolean
---@field highlights diffs.Highlights
---@field fugitive diffs.FugitiveConfig

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
  debounce_ms = 0,
  hide_prefix = false,
  highlights = {
    background = true,
    gutter = true,
    treesitter = {
      enabled = true,
      max_lines = 500,
    },
    vim = {
      enabled = false,
      max_lines = 200,
    },
    intra = {
      enabled = true,
      algorithm = 'default',
      max_lines = 500,
    },
  },
  fugitive = {
    horizontal = 'du',
    vertical = 'dU',
  },
}

---@type diffs.Config
local config = vim.deepcopy(default_config)

local initialized = false

---@type table<integer, boolean>
local attached_buffers = {}

---@type table<integer, boolean>
local diff_windows = {}

---@param bufnr integer
---@return boolean
function M.is_fugitive_buffer(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):match('^fugitive://') ~= nil
end

local dbg = log.dbg

---@param bufnr integer
local function highlight_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local hunks = parser.parse_buffer(bufnr)
  dbg('found %d hunks in buffer %d', #hunks, bufnr)
  for _, hunk in ipairs(hunks) do
    highlight.highlight_hunk(bufnr, ns, hunk, {
      hide_prefix = config.hide_prefix,
      highlights = config.highlights,
    })
  end
end

---@param bufnr integer
---@return fun()
local function create_debounced_highlight(bufnr)
  local timer = nil ---@type table?
  return function()
    if timer then
      timer:stop() ---@diagnostic disable-line: undefined-field
      timer:close() ---@diagnostic disable-line: undefined-field
      timer = nil
    end
    local t = vim.uv.new_timer()
    if not t then
      highlight_buffer(bufnr)
      return
    end
    timer = t
    t:start(
      config.debounce_ms,
      0,
      vim.schedule_wrap(function()
        if timer == t then
          timer = nil
          t:close()
        end
        highlight_buffer(bufnr)
      end)
    )
  end
end

local function compute_highlight_groups()
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
  local diff_add = vim.api.nvim_get_hl(0, { name = 'DiffAdd' })
  local diff_delete = vim.api.nvim_get_hl(0, { name = 'DiffDelete' })
  local diff_added = resolve_hl('diffAdded')
  local diff_removed = resolve_hl('diffRemoved')

  local bg = normal.bg or 0x1e1e2e
  local add_bg = diff_add.bg or 0x2e4a3a
  local del_bg = diff_delete.bg or 0x4a2e3a
  local add_fg = diff_added.fg or diff_add.fg or 0x80c080
  local del_fg = diff_removed.fg or diff_delete.fg or 0xc08080

  local blended_add = blend_color(add_bg, bg, 0.4)
  local blended_del = blend_color(del_bg, bg, 0.4)

  local blended_add_text = blend_color(add_fg, bg, 0.7)
  local blended_del_text = blend_color(del_fg, bg, 0.7)

  vim.api.nvim_set_hl(0, 'DiffsClear', { default = true, fg = normal.fg or 0xc0c0c0 })
  vim.api.nvim_set_hl(0, 'DiffsAdd', { default = true, bg = blended_add })
  vim.api.nvim_set_hl(0, 'DiffsDelete', { default = true, bg = blended_del })
  vim.api.nvim_set_hl(0, 'DiffsAddNr', { default = true, fg = add_fg, bg = blended_add })
  vim.api.nvim_set_hl(0, 'DiffsDeleteNr', { default = true, fg = del_fg, bg = blended_del })
  vim.api.nvim_set_hl(0, 'DiffsAddText', { default = true, bg = blended_add_text })
  vim.api.nvim_set_hl(0, 'DiffsDeleteText', { default = true, bg = blended_del_text })

  dbg('highlight groups: Normal.bg=#%06x DiffAdd.bg=#%06x diffAdded.fg=#%06x', bg, add_bg, add_fg)
  dbg(
    'DiffsAdd.bg=#%06x DiffsAddText.bg=#%06x DiffsAddNr.fg=#%06x',
    blended_add,
    blended_add_text,
    add_fg
  )
  dbg('DiffsDelete.bg=#%06x DiffsDeleteText.bg=#%06x', blended_del, blended_del_text)

  local diff_change = resolve_hl('DiffChange')
  local diff_text = resolve_hl('DiffText')

  vim.api.nvim_set_hl(0, 'DiffsDiffAdd', { bg = diff_add.bg })
  vim.api.nvim_set_hl(0, 'DiffsDiffDelete', { fg = diff_delete.fg, bg = diff_delete.bg })
  vim.api.nvim_set_hl(0, 'DiffsDiffChange', { bg = diff_change.bg })
  vim.api.nvim_set_hl(0, 'DiffsDiffText', { bg = diff_text.bg })
end

local function init()
  if initialized then
    return
  end
  initialized = true

  local opts = vim.g.diffs or {}

  vim.validate({
    debug = { opts.debug, 'boolean', true },
    debounce_ms = { opts.debounce_ms, 'number', true },
    hide_prefix = { opts.hide_prefix, 'boolean', true },
    highlights = { opts.highlights, 'table', true },
  })

  if opts.highlights then
    vim.validate({
      ['highlights.background'] = { opts.highlights.background, 'boolean', true },
      ['highlights.gutter'] = { opts.highlights.gutter, 'boolean', true },
      ['highlights.treesitter'] = { opts.highlights.treesitter, 'table', true },
      ['highlights.vim'] = { opts.highlights.vim, 'table', true },
      ['highlights.intra'] = { opts.highlights.intra, 'table', true },
    })

    if opts.highlights.treesitter then
      vim.validate({
        ['highlights.treesitter.enabled'] = { opts.highlights.treesitter.enabled, 'boolean', true },
        ['highlights.treesitter.max_lines'] = {
          opts.highlights.treesitter.max_lines,
          'number',
          true,
        },
      })
    end

    if opts.highlights.vim then
      vim.validate({
        ['highlights.vim.enabled'] = { opts.highlights.vim.enabled, 'boolean', true },
        ['highlights.vim.max_lines'] = { opts.highlights.vim.max_lines, 'number', true },
      })
    end

    if opts.highlights.intra then
      vim.validate({
        ['highlights.intra.enabled'] = { opts.highlights.intra.enabled, 'boolean', true },
        ['highlights.intra.algorithm'] = {
          opts.highlights.intra.algorithm,
          function(v)
            return v == nil or v == 'default' or v == 'vscode'
          end,
          "'default' or 'vscode'",
        },
        ['highlights.intra.max_lines'] = { opts.highlights.intra.max_lines, 'number', true },
      })
    end
  end

  if opts.fugitive then
    vim.validate({
      ['fugitive.horizontal'] = {
        opts.fugitive.horizontal,
        function(v)
          return v == false or type(v) == 'string'
        end,
        'string or false',
      },
      ['fugitive.vertical'] = {
        opts.fugitive.vertical,
        function(v)
          return v == false or type(v) == 'string'
        end,
        'string or false',
      },
    })
  end

  if opts.debounce_ms and opts.debounce_ms < 0 then
    error('diffs: debounce_ms must be >= 0')
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

  config = vim.tbl_deep_extend('force', default_config, opts)
  log.set_enabled(config.debug)

  compute_highlight_groups()

  vim.api.nvim_create_autocmd('ColorScheme', {
    callback = function()
      compute_highlight_groups()
      for bufnr, _ in pairs(attached_buffers) do
        highlight_buffer(bufnr)
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

  dbg('attaching to buffer %d', bufnr)

  local debounced = create_debounced_highlight(bufnr)

  highlight_buffer(bufnr)

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = bufnr,
    callback = debounced,
  })

  vim.api.nvim_create_autocmd('Syntax', {
    buffer = bufnr,
    callback = function()
      dbg('syntax event, re-highlighting buffer %d', bufnr)
      highlight_buffer(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd('BufReadPost', {
    buffer = bufnr,
    callback = function()
      dbg('BufReadPost event, re-highlighting buffer %d', bufnr)
      highlight_buffer(bufnr)
    end,
  })

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      attached_buffers[bufnr] = nil
    end,
  })
end

---@param bufnr? integer
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  highlight_buffer(bufnr)
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

---@return diffs.FugitiveConfig
function M.get_fugitive_config()
  init()
  return config.fugitive
end

return M
