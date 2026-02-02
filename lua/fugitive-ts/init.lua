---@class fugitive-ts.Config
---@field enabled boolean
---@field debug boolean
---@field languages table<string, string>
---@field disabled_languages string[]
---@field highlight_headers boolean
---@field debounce_ms integer
---@field max_lines_per_hunk integer

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
  highlight_headers = true,
  debounce_ms = 50,
  max_lines_per_hunk = 500,
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

  local hunks =
    parser.parse_buffer(bufnr, config.languages, config.disabled_languages, config.debug)
  dbg('found %d hunks in buffer %d', #hunks, bufnr)
  for _, hunk in ipairs(hunks) do
    highlight.highlight_hunk(
      bufnr,
      ns,
      hunk,
      config.max_lines_per_hunk,
      config.highlight_headers,
      config.debug
    )
  end
end

---@param bufnr integer
---@return fun()
local function create_debounced_highlight(bufnr)
  ---@type uv_timer_t?
  local timer = nil
  return function()
    if timer then
      timer:stop()
      timer:close()
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
        t:close()
        if timer == t then
          timer = nil
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
  config = vim.tbl_deep_extend('force', default_config, opts)
end

return M
