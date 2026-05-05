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
---@field line_count integer
---@field byte_count integer

---@class diffs.Cache
---@field ns integer
---@field get_config fun(): diffs.Config
---@field hunk_cache table<integer, diffs.HunkCacheEntry>
---@field ft_retry_pending table<integer, boolean>
---@field syntax_jobs table<integer, integer>

---@class diffs.CacheOpts
---@field ns integer
---@field get_config fun(): diffs.Config

local Cache = {}
Cache.__index = Cache

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
function M.compute_hunk_context(hunks, max_lines)
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

---@param a diffs.Hunk
---@param b diffs.Hunk
---@return boolean
function M.hunks_eq(a, b)
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
    if not M.hunks_eq(old_hunks[i], new_hunks[i]) then
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
    if not M.hunks_eq(old_hunks[old_idx], new_hunks[new_idx]) then
      break
    end
    if old_hl[old_idx] then
      highlighted[new_idx] = true
    end
    suffix_len = j + 1
  end

  log.dbg(
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
    get_config = opts.get_config,
    hunk_cache = {},
    ft_retry_pending = {},
    syntax_jobs = {},
  }, Cache)
end

---@param bufnr integer
---@return integer
function Cache:next_syntax_job(bufnr)
  local job_id = (self.syntax_jobs[bufnr] or 0) + 1
  self.syntax_jobs[bufnr] = job_id
  return job_id
end

---@param hunks diffs.Hunk[]?
---@return diffs.Hunk[]
function Cache:collect_syntax_hunks(hunks)
  local config = self.get_config()
  local syntax_hunks = {}
  for _, hunk in ipairs(hunks or {}) do
    local has_syntax = hunk.lang and config.highlights.treesitter.enabled
    local needs_vim = not hunk.lang and hunk.ft and config.highlights.vim.enabled
    if has_syntax or needs_vim then
      syntax_hunks[#syntax_hunks + 1] = hunk
    end
  end
  return syntax_hunks
end

---@param bufnr integer
---@param tick integer
---@param changedtick integer
---@param job_id integer
---@param deferred_syntax diffs.Hunk[]
---@return boolean
function Cache:run_deferred_syntax(bufnr, tick, changedtick, job_id, deferred_syntax)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if self.syntax_jobs[bufnr] ~= job_id then
    log.dbg(
      'deferred syntax job superseded: cur=%s job=%d',
      tostring(self.syntax_jobs[bufnr]),
      job_id
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
  local syntax_opts = {
    hide_prefix = config.hide_prefix,
    highlights = config.highlights,
    syntax_only = true,
  }
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
  self.syntax_jobs[bufnr] = (self.syntax_jobs[bufnr] or 0) + 1
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
  if entry and not entry.pending_clear then
    local lc = vim.api.nvim_buf_line_count(bufnr)
    local bc = vim.api.nvim_buf_get_offset(bufnr, lc)
    if lc == entry.line_count and bc == entry.byte_count then
      entry.tick = tick
      entry.pending_clear = true
      log.dbg('content unchanged in buffer %d (tick %d), skipping reparse', bufnr, tick)
      return
    end
  end
  local hunks = parser.parse_buffer(bufnr)
  local lc = vim.api.nvim_buf_line_count(bufnr)
  local bc = vim.api.nvim_buf_get_offset(bufnr, lc)
  log.dbg('parsed %d hunks in buffer %d (tick %d)', #hunks, bufnr, tick)
  local config = self.get_config()
  if config.highlights.context.enabled then
    M.compute_hunk_context(hunks, config.highlights.context.lines)
  end
  local carried = entry
    and not entry.pending_clear
    and #entry.hunks == #hunks
    and carry_forward_highlighted(entry, hunks)
  self.hunk_cache[bufnr] = {
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
  if has_nil_ft and vim.fn.did_filetype() ~= 0 and not self.ft_retry_pending[bufnr] then
    self.ft_retry_pending[bufnr] = true
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) and self.hunk_cache[bufnr] then
        log.dbg('retrying filetype detection for buffer %d (was blocked by did_filetype)', bufnr)
        self:invalidate(bufnr)
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
function Cache:delete(bufnr)
  self.hunk_cache[bufnr] = nil
  self.ft_retry_pending[bufnr] = nil
  self.syntax_jobs[bufnr] = nil
end

return M
