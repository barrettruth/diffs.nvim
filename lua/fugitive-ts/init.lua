---@class fugitive-ts.Config
---@field enabled boolean
---@field languages table<string, string>
---@field debounce_ms integer

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
  languages = {},
  debounce_ms = 50,
}

---@type fugitive-ts.Config
local config = vim.deepcopy(default_config)

---@type table<integer, boolean>
local attached_buffers = {}

---@param bufnr integer
local function highlight_buffer(bufnr)
  if not config.enabled then
    return
  end

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  local hunks = parser.parse_buffer(bufnr, config.languages)
  for _, hunk in ipairs(hunks) do
    highlight.highlight_hunk(bufnr, ns, hunk)
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
    end
    timer = vim.uv.new_timer()
    timer:start(
      config.debounce_ms,
      0,
      vim.schedule_wrap(function()
        timer:close()
        timer = nil
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

  local debounced = create_debounced_highlight(bufnr)

  highlight_buffer(bufnr)

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = bufnr,
    callback = debounced,
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
