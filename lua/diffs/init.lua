---@class diffs
---@field attach fun(bufnr?: integer)
---@field refresh fun(bufnr?: integer)
local M = {}

local cache_mod = require('diffs.cache')
local config_mod = require('diffs.config')
local decorator = require('diffs.decorator')
local highlight_groups = require('diffs.highlight_groups')
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

---@param bufnr integer
---@return boolean
function M.is_fugitive_buffer(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):match('^fugitive://') ~= nil
end

M.compute_filetypes = config_mod.compute_filetypes

local dbg = log.dbg

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

  cache:ensure(bufnr)

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      attached_buffers[bufnr] = nil
      cache:delete(bufnr)
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
  cache:invalidate(bufnr)
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
