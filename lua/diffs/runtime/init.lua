---@class diffs
---@field attach fun(bufnr?: integer, options?: diffs.AttachOptions)
---@field refresh fun(bufnr?: integer)
local M = {}

local attach_mod = require('diffs.runtime.attach')
local cache_mod = require('diffs.runtime.cache')
local config_mod = require('diffs.config')
local decorator = require('diffs.runtime.decorator')
local diff_windows_mod = require('diffs.runtime.diff_windows')
local highlight = require('diffs.highlight')
local highlight_groups = require('diffs.runtime.highlight_groups')
local log = require('diffs.log')

local ns = vim.api.nvim_create_namespace('diffs')

---@type diffs.Config
local config = config_mod.new()

---@type table<integer, diffs.Attachment>
local attached_buffers = {}

local cache = cache_mod.new({
  get_attachment = function(bufnr)
    return attached_buffers[bufnr]
  end,
  ns = ns,
  get_config = function()
    return config
  end,
})

local initialized = false
local configured = false
local hl_retry_pending = false

---@diagnostic disable-next-line: missing-fields
local fast_hl_opts = {} ---@type diffs.HunkOpts

---@type table<integer, string>
local diff_windows = {}

local function compute_highlight_groups(is_default)
  local result = highlight_groups.apply(config, is_default)
  if result.transparent and not hl_retry_pending then
    hl_retry_pending = true
    vim.schedule(function()
      compute_highlight_groups(false)
      for bufnr, _ in pairs(attached_buffers) do
        cache:invalidate(bufnr)
      end
    end)
  end
end

local function init()
  if initialized then
    return
  end
  initialized = true

  if not configured then
    config = config_mod.new(vim.g.diffs or {})
  end
  log.set_enabled(config.debug)

  fast_hl_opts = highlight.hunk_opts(config, {
    highlights = {
      treesitter = false,
    },
    defer_vim_syntax = true,
  })

  compute_highlight_groups(true)

  vim.api.nvim_create_autocmd('ColorScheme', {
    callback = function()
      hl_retry_pending = false
      compute_highlight_groups(false)
      for bufnr, _ in pairs(attached_buffers) do
        cache:invalidate(bufnr)
      end
    end,
  })

  decorator.setup({
    ns = ns,
    cache = cache,
    attached_buffers = attached_buffers,
    get_config = function()
      return config
    end,
    get_fast_hl_opts = function()
      return fast_hl_opts
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    callback = function(args)
      diff_windows_mod.forget(diff_windows, tonumber(args.match))
    end,
  })
end

---@param user_config diffs.Config
function M.configure(user_config)
  if initialized then
    return
  end
  config = user_config
  configured = true
end

---@param bufnr? integer
---@param options? diffs.AttachOptions
function M.attach(bufnr, options)
  init()
  attach_mod.attach({
    cache = cache,
    attached_buffers = attached_buffers,
    get_config = function()
      return config
    end,
    refresh = M.refresh,
  }, bufnr, options)
end

---@param bufnr? integer
function M.detach(bufnr)
  attach_mod.detach({ cache = cache, attached_buffers = attached_buffers }, bufnr)
end

---@param bufnr? integer
function M.refresh(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  cache:invalidate(bufnr)
end

--- Eagerly clear and re-arm every attached buffer's highlights so the next
--- redraw repaints them. Used when a global change (such as 'diffopt') affects
--- how all surfaces are highlighted. The clear is done eagerly rather than via
--- the lazy pending_clear flag because the decoration provider's on_buf hook
--- (which would process that flag) is not invoked by a bare redraw.
function M.invalidate_attached()
  init()
  for bufnr, _ in pairs(attached_buffers) do
    cache:reset_highlights(bufnr)
  end
end

function M.attach_diff()
  init()
  diff_windows_mod.attach(diff_windows)
end

function M.detach_diff()
  diff_windows_mod.detach(diff_windows)
end

---@return diffs.HunkOpts
function M.get_highlight_opts()
  init()
  return highlight.hunk_opts(config)
end

M._test = {
  find_visible_hunks = cache_mod.find_visible_hunks,
  hunk_cache = cache.hunk_cache,
  ensure_cache = function(bufnr)
    cache:ensure(bufnr)
  end,
  invalidate_cache = function(bufnr)
    cache:invalidate(bufnr)
  end,
  process_pending_clear = function(bufnr)
    cache:process_pending_clear(bufnr)
  end,
  clear_ns_by_start = cache_mod.clear_ns_by_start,
  ft_retry_pending = cache.ft_retry_pending,
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
  next_syntax_job = function(bufnr)
    return cache:next_syntax_job(bufnr)
  end,
  run_deferred_syntax = function(bufnr, tick, changedtick, job_id, deferred_syntax)
    return cache:run_deferred_syntax(bufnr, tick, changedtick, job_id, deferred_syntax)
  end,
}

return M
