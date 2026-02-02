---@class fugitive-ts.Highlights
---@field treesitter boolean
---@field background boolean
---@field gutter boolean
---@field vim boolean

---@class fugitive-ts.Config
---@field enabled boolean
---@field debug boolean
---@field languages table<string, string>
---@field disabled_languages string[]
---@field debounce_ms integer
---@field max_lines_per_hunk integer
---@field conceal_prefixes boolean
---@field highlights fugitive-ts.Highlights

---@class fugitive-ts
---@field attach fun(bufnr?: integer)
---@field refresh fun(bufnr?: integer)
---@field setup fun(opts?: fugitive-ts.Config)
local M = {}

local highlight = require('fugitive-ts.highlight')
local parser = require('fugitive-ts.parser')

local ns = vim.api.nvim_create_namespace('fugitive_ts')

---@type fugitive-ts.Config
local default_config = {
  enabled = true,
  debug = false,
  languages = {},
  disabled_languages = {},
  debounce_ms = 50,
  max_lines_per_hunk = 500,
  conceal_prefixes = true,
  highlights = {
    treesitter = true,
    background = true,
    gutter = true,
    vim = false,
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

  local hunks = parser.parse_buffer(bufnr, config.languages, config.disabled_languages)
  dbg('found %d hunks in buffer %d', #hunks, bufnr)
  for _, hunk in ipairs(hunks) do
    highlight.highlight_hunk(bufnr, ns, hunk, {
      max_lines = config.max_lines_per_hunk,
      conceal_prefixes = config.conceal_prefixes,
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

---@param opts? fugitive-ts.Config
function M.setup(opts)
  opts = opts or {}

  vim.validate({
    enabled = { opts.enabled, 'boolean', true },
    debug = { opts.debug, 'boolean', true },
    languages = { opts.languages, 'table', true },
    disabled_languages = { opts.disabled_languages, 'table', true },
    debounce_ms = { opts.debounce_ms, 'number', true },
    max_lines_per_hunk = { opts.max_lines_per_hunk, 'number', true },
    conceal_prefixes = { opts.conceal_prefixes, 'boolean', true },
    highlights = { opts.highlights, 'table', true },
  })

  if opts.highlights then
    vim.validate({
      ['highlights.treesitter'] = { opts.highlights.treesitter, 'boolean', true },
      ['highlights.background'] = { opts.highlights.background, 'boolean', true },
      ['highlights.gutter'] = { opts.highlights.gutter, 'boolean', true },
      ['highlights.vim'] = { opts.highlights.vim, 'boolean', true },
    })
  end

  config = vim.tbl_deep_extend('force', default_config, opts)
  parser.set_debug(config.debug)
  highlight.set_debug(config.debug)

  local diff_add = vim.api.nvim_get_hl(0, { name = 'DiffAdd' })
  local diff_delete = vim.api.nvim_get_hl(0, { name = 'DiffDelete' })
  vim.api.nvim_set_hl(0, 'FugitiveTsAdd', { bg = diff_add.bg })
  vim.api.nvim_set_hl(0, 'FugitiveTsDelete', { bg = diff_delete.bg })
end

return M
