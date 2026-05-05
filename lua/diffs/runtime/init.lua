---@class diffs
---@field attach fun(bufnr?: integer)
---@field refresh fun(bufnr?: integer)
local M = {}

local attach_mod = require('diffs.runtime.attach')
local cache_mod = require('diffs.runtime.cache')
local config_mod = require('diffs.config')
local decorator = require('diffs.runtime.decorator')
local diff_windows_mod = require('diffs.runtime.diff_windows')
local highlight_groups = require('diffs.runtime.highlight_groups')
local log = require('diffs.log')

local ns = vim.api.nvim_create_namespace('diffs')

---@type diffs.Config
local config = config_mod.new()

local cache = cache_mod.new({
  ns = ns,
  get_config = function()
    return config
  end,
})

local initialized = false
local hl_retry_pending = false

---@diagnostic disable-next-line: missing-fields
local fast_hl_opts = {} ---@type diffs.HunkOpts

---@type table<integer, boolean>
local attached_buffers = {}

---@type table<integer, boolean>
local diff_windows = {}

---@type fun(bufnr: integer): boolean
M.is_fugitive_buffer = attach_mod.is_fugitive_buffer

M.compute_filetypes = config_mod.compute_filetypes

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

  config = config_mod.new(vim.g.diffs or {})
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

---@param bufnr? integer
function M.attach(bufnr)
  init()
  attach_mod.attach({
    cache = cache,
    attached_buffers = attached_buffers,
    get_config = function()
      return config
    end,
    refresh = M.refresh,
  }, bufnr)
end

---@param bufnr? integer
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  cache:invalidate(bufnr)
end

function M.attach_diff()
  init()
  diff_windows_mod.attach(diff_windows)
end

function M.detach_diff()
  diff_windows_mod.detach(diff_windows)
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

M._test = {
  find_visible_hunks = cache_mod.find_visible_hunks,
  hunk_cache = cache.hunk_cache,
  ensure_cache = function(bufnr)
    cache:ensure(bufnr)
  end,
  invalidate_cache = function(bufnr)
    cache:invalidate(bufnr)
  end,
  hunks_eq = cache_mod.hunks_eq,
  process_pending_clear = function(bufnr)
    cache:process_pending_clear(bufnr)
  end,
  clear_ns_by_start = cache_mod.clear_ns_by_start,
  ft_retry_pending = cache.ft_retry_pending,
  compute_hunk_context = cache_mod.compute_hunk_context,
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
