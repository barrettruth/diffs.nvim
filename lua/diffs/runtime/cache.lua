local highlight = require('diffs.highlight')
local log = require('diffs.log')
local parser = require('diffs.parser')

local M = {}

---@class diffs.HunkCacheEntry
---@field hunks diffs.Hunk[]
---@field tick integer
---@field highlighted table<integer, true>
---@field pending_clear boolean
---@field warned_max_lines boolean

---@class diffs.Cache
---@field ns integer
---@field get_config fun(): diffs.Config
---@field get_attachment? fun(bufnr: integer): diffs.Attachment?
---@field hunk_cache table<integer, diffs.HunkCacheEntry>
---@field ft_retry_pending table<integer, table>
---@field syntax_jobs table<integer, table>

---@class diffs.CacheOpts
---@field ns integer
---@field get_config fun(): diffs.Config
---@field get_attachment? fun(bufnr: integer): diffs.Attachment?

local Cache = {}
Cache.__index = Cache

---@param hunks diffs.Hunk[]
---@param toprow integer
---@param botrow integer
---@return integer first
---@return integer last
function M.find_visible_hunks(hunks, toprow, botrow)
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

---@param bufnr integer
---@param ns_id integer
---@param start_row integer
---@param end_row integer
function M.clear_ns_by_start(bufnr, ns_id, start_row, end_row)
  local marks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    ns_id,
    { start_row, 0 },
    { end_row - 1, 2147483647 },
    {}
  )
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_del_extmark(bufnr, ns_id, m[1])
  end
end

---@param opts diffs.CacheOpts
---@return diffs.Cache
function M.new(opts)
  return setmetatable({
    ns = opts.ns,
    get_attachment = opts.get_attachment,
    get_config = opts.get_config,
    hunk_cache = {},
    ft_retry_pending = {},
    syntax_jobs = {},
  }, Cache)
end

---@param bufnr integer
---@return table
function Cache:next_syntax_job(bufnr)
  local job_id = {}
  self.syntax_jobs[bufnr] = job_id
  return job_id
end

---@param hunk diffs.Hunk
---@param vim_cache_hit? boolean
---@return boolean
function Cache:needs_syntax(hunk, vim_cache_hit)
  local highlights = self.get_config().highlights
  if
    hunk.lang
    or (hunk.header_start_line and hunk.header_lines and #hunk.header_lines > 0)
    or (hunk.quote_width or 0) > 0
    or (hunk.prefix_width or 1) > 1
  then
    return true
  end
  return not hunk.lang and hunk.ft ~= nil and highlights.vim and not vim_cache_hit
end

---@param hunks diffs.Hunk[]?
---@return diffs.Hunk[]
function Cache:collect_syntax_hunks(hunks)
  local syntax_hunks = {}
  for _, hunk in ipairs(hunks or {}) do
    if self:needs_syntax(hunk) then
      syntax_hunks[#syntax_hunks + 1] = hunk
    end
  end
  return syntax_hunks
end

---@param bufnr integer
---@param tick integer
---@param changedtick integer
---@param job_id table
---@param deferred_syntax diffs.Hunk[]
---@return boolean
function Cache:run_deferred_syntax(bufnr, tick, changedtick, job_id, deferred_syntax)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if self.syntax_jobs[bufnr] ~= job_id then
    log.dbg(
      'deferred syntax job superseded: cur=%s job=%s',
      tostring(self.syntax_jobs[bufnr]),
      tostring(job_id)
    )
    return false
  end
  local live_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  if live_changedtick ~= changedtick then
    log.dbg(
      'deferred syntax changedtick changed: cur=%d captured=%d',
      live_changedtick,
      changedtick
    )
    return false
  end
  local cur = self.hunk_cache[bufnr]
  if not cur then
    return false
  end
  local hunks_to_hl = deferred_syntax
  if cur.tick ~= tick then
    log.dbg(
      'deferred syntax tick changed: cur.tick=%s captured=%d, using current hunks',
      tostring(cur.tick),
      tick
    )
    hunks_to_hl = self:collect_syntax_hunks(cur.hunks or {})
    if #hunks_to_hl == 0 then
      return false
    end
    live_changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
    if live_changedtick ~= changedtick then
      log.dbg(
        'deferred syntax changedtick changed after refresh: cur=%d captured=%d',
        live_changedtick,
        changedtick
      )
      return false
    end
  end
  local config = self.get_config()
  local t1 = config.debug and vim.uv.hrtime() or nil
  local syntax_opts = highlight.hunk_opts(config, {
    syntax_only = true,
  })
  for _, hunk in ipairs(hunks_to_hl) do
    highlight.highlight_hunk(bufnr, self.ns, hunk, syntax_opts)
  end
  if t1 then
    log.dbg('deferred pass: %d hunks in %.2fms', #hunks_to_hl, (vim.uv.hrtime() - t1) / 1e6)
  end
  return true
end

---@param bufnr integer
function Cache:invalidate(bufnr)
  self.syntax_jobs[bufnr] = {}
  local entry = self.hunk_cache[bufnr]
  if entry then
    entry.tick = -1
    entry.pending_clear = true
  end
end

---@param bufnr integer
function Cache:ensure(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local entry = self.hunk_cache[bufnr]
  if entry and entry.tick == tick then
    return
  end
  local attachment = self.get_attachment and self.get_attachment(bufnr)
  local hunks = attachment and attachment.hunks and vim.deepcopy(attachment.hunks(bufnr))
    or parser.parse_buffer(bufnr)
  log.dbg('parsed %d hunks in buffer %d (tick %d)', #hunks, bufnr, tick)
  self.hunk_cache[bufnr] = {
    hunks = hunks,
    tick = tick,
    highlighted = {},
    pending_clear = true,
    warned_max_lines = false,
  }

  local has_nil_ft = false
  for _, hunk in ipairs(hunks) do
    if not has_nil_ft and not hunk.ft and hunk.filename then
      has_nil_ft = true
    end
  end
  if
    not (attachment and attachment.hunks)
    and has_nil_ft
    and vim.fn.did_filetype() ~= 0
    and not self.ft_retry_pending[bufnr]
  then
    local retry = {}
    self.ft_retry_pending[bufnr] = retry
    vim.schedule(function()
      if self.ft_retry_pending[bufnr] ~= retry then
        return
      end
      if vim.api.nvim_buf_is_valid(bufnr) and self.hunk_cache[bufnr] then
        log.dbg('retrying filetype detection for buffer %d (was blocked by did_filetype)', bufnr)
        self:invalidate(bufnr)
        self:ensure(bufnr)
        self:process_pending_clear(bufnr)
        vim.cmd('redraw!')
      end
      self.ft_retry_pending[bufnr] = nil
    end)
  end
end

---@param bufnr integer
function Cache:process_pending_clear(bufnr)
  local entry = self.hunk_cache[bufnr]
  if entry and entry.pending_clear then
    vim.api.nvim_buf_clear_namespace(bufnr, self.ns, 0, -1)
    entry.highlighted = {}
    entry.pending_clear = false
  end
end

---@param bufnr integer
function Cache:reset_highlights(bufnr)
  local entry = self.hunk_cache[bufnr]
  if not entry or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, self.ns, 0, -1)
  entry.highlighted = {}
  entry.pending_clear = false
end

---@param bufnr integer
function Cache:delete(bufnr)
  self.hunk_cache[bufnr] = nil
  self.ft_retry_pending[bufnr] = nil
  self.syntax_jobs[bufnr] = nil
end

return M
