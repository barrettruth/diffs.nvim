---@class fugitive-ts.Highlights
---@field background boolean
---@field gutter boolean

---@class fugitive-ts.TreesitterConfig
---@field enabled boolean
---@field max_lines integer

---@class fugitive-ts.VimConfig
---@field enabled boolean
---@field max_lines integer

---@class fugitive-ts.Config
---@field enabled boolean
---@field debug boolean
---@field debounce_ms integer
---@field hide_prefix boolean
---@field treesitter fugitive-ts.TreesitterConfig
---@field vim fugitive-ts.VimConfig
---@field highlights fugitive-ts.Highlights

---@class fugitive-ts
---@field attach fun(bufnr?: integer)
---@field refresh fun(bufnr?: integer)
---@field setup fun(opts?: fugitive-ts.Config)
local M = {}

local highlight = require('fugitive-ts.highlight')
local parser = require('fugitive-ts.parser')

local ns = vim.api.nvim_create_namespace('fugitive_ts')

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

---@type fugitive-ts.Config
local default_config = {
  enabled = true,
  debug = false,
  debounce_ms = 0,
  hide_prefix = false,
  treesitter = {
    enabled = true,
    max_lines = 500,
  },
  vim = {
    enabled = false,
    max_lines = 200,
  },
  highlights = {
    background = true,
    gutter = true,
  },
}

---@type fugitive-ts.Config
local config = vim.deepcopy(default_config)

---@type table<integer, boolean>
local attached_buffers = {}

---@param msg string
---@param ... any
local function dbg(msg, ...)
  if not config.debug then
    return
  end
  local formatted = string.format(msg, ...)
  vim.notify('[fugitive-ts] ' .. formatted, vim.log.levels.DEBUG)
end

---@param bufnr integer
local function highlight_buffer(bufnr)
  if not config.enabled then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local hunks = parser.parse_buffer(bufnr)
  dbg('found %d hunks in buffer %d', #hunks, bufnr)
  for _, hunk in ipairs(hunks) do
    highlight.highlight_hunk(bufnr, ns, hunk, {
      hide_prefix = config.hide_prefix,
      treesitter = config.treesitter,
      vim = config.vim,
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

---@param bufnr? integer
function M.attach(bufnr)
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

  vim.api.nvim_set_hl(0, 'FugitiveTsAdd', { bg = blended_add })
  vim.api.nvim_set_hl(0, 'FugitiveTsDelete', { bg = blended_del })
  vim.api.nvim_set_hl(0, 'FugitiveTsAddNr', { fg = add_fg, bg = blended_add })
  vim.api.nvim_set_hl(0, 'FugitiveTsDeleteNr', { fg = del_fg, bg = blended_del })
end

---@param opts? fugitive-ts.Config
function M.setup(opts)
  opts = opts or {}

  vim.validate({
    enabled = { opts.enabled, 'boolean', true },
    debug = { opts.debug, 'boolean', true },
    debounce_ms = { opts.debounce_ms, 'number', true },
    hide_prefix = { opts.hide_prefix, 'boolean', true },
    treesitter = { opts.treesitter, 'table', true },
    vim = { opts.vim, 'table', true },
    highlights = { opts.highlights, 'table', true },
  })

  if opts.treesitter then
    vim.validate({
      ['treesitter.enabled'] = { opts.treesitter.enabled, 'boolean', true },
      ['treesitter.max_lines'] = { opts.treesitter.max_lines, 'number', true },
    })
  end

  if opts.vim then
    vim.validate({
      ['vim.enabled'] = { opts.vim.enabled, 'boolean', true },
      ['vim.max_lines'] = { opts.vim.max_lines, 'number', true },
    })
  end

  if opts.highlights then
    vim.validate({
      ['highlights.background'] = { opts.highlights.background, 'boolean', true },
      ['highlights.gutter'] = { opts.highlights.gutter, 'boolean', true },
    })
  end

  config = vim.tbl_deep_extend('force', default_config, opts)
  parser.set_debug(config.debug)
  highlight.set_debug(config.debug)

  compute_highlight_groups()

  vim.api.nvim_create_autocmd('ColorScheme', {
    callback = function()
      compute_highlight_groups()
      for bufnr, _ in pairs(attached_buffers) do
        highlight_buffer(bufnr)
      end
    end,
  })
end

return M
