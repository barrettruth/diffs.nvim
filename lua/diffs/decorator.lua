local cache_mod = require('diffs.cache')
local highlight = require('diffs.highlight')
local log = require('diffs.log')

local M = {}

---@class diffs.DecoratorOpts
---@field ns integer
---@field cache diffs.Cache
---@field attached_buffers table<integer, boolean>
---@field get_config fun(): diffs.Config
---@field get_fast_hl_opts fun(): diffs.HunkOpts

---@param opts diffs.DecoratorOpts
function M.setup(opts)
  local ns = opts.ns
  local cache = opts.cache
  local attached_buffers = opts.attached_buffers

  vim.api.nvim_set_decoration_provider(ns, {
    on_buf = function(_, bufnr)
      if not attached_buffers[bufnr] then
        return false
      end
      local config = opts.get_config()
      local t0 = config.debug and vim.uv.hrtime() or nil
      cache:ensure(bufnr)
      cache:process_pending_clear(bufnr)
      if t0 then
        log.dbg('on_buf %d: %.2fms', bufnr, (vim.uv.hrtime() - t0) / 1e6)
      end
    end,
    on_win = function(_, _, bufnr, toprow, botrow)
      if not attached_buffers[bufnr] then
        return false
      end
      local entry = cache.hunk_cache[bufnr]
      if not entry then
        return
      end
      local first, last = cache_mod.find_visible_hunks(entry.hunks, toprow, botrow)
      if first == 0 then
        return
      end
      local config = opts.get_config()
      local t0 = config.debug and vim.uv.hrtime() or nil
      local deferred_syntax = {}
      local skipped_count = 0
      local count = 0
      local fast_hl_opts = opts.get_fast_hl_opts()
      for i = first, last do
        if not entry.highlighted[i] then
          local hunk = entry.hunks[i]
          local clear_start = hunk.start_line - 1
          local clear_end = hunk.start_line + #hunk.lines
          if hunk.header_start_line then
            clear_start = hunk.header_start_line - 1
          end
          cache_mod.clear_ns_by_start(bufnr, ns, clear_start, clear_end)
          local _, vim_cache_hit = highlight.highlight_hunk(bufnr, ns, hunk, fast_hl_opts)
          entry.highlighted[i] = true
          count = count + 1
          if hunk._skipped_max_lines then
            skipped_count = skipped_count + 1
          end
          local has_syntax = hunk.lang and config.highlights.treesitter.enabled
          local needs_vim = not hunk.lang
            and hunk.ft
            and config.highlights.vim.enabled
            and not vim_cache_hit
          if has_syntax or needs_vim then
            table.insert(deferred_syntax, hunk)
          end
        end
      end
      if skipped_count > 0 and not entry.warned_max_lines and config.highlights.warn_max_lines then
        entry.warned_max_lines = true
        local n = skipped_count
        vim.schedule(function()
          vim.notify(
            (
              '[diffs.nvim]: Syntax highlighting skipped for %d hunk(s) — too large.'
              .. ' See :h diffs-max-lines to resolve or suppress this warning.'
            ):format(n),
            vim.log.levels.WARN
          )
        end)
      end
      if #deferred_syntax > 0 then
        local tick = entry.tick
        local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
        local job_id = cache:next_syntax_job(bufnr)
        log.dbg(
          'deferred syntax scheduled: %d hunks tick=%d changedtick=%d job=%d',
          #deferred_syntax,
          tick,
          changedtick,
          job_id
        )
        vim.schedule(function()
          cache:run_deferred_syntax(bufnr, tick, changedtick, job_id, deferred_syntax)
        end)
      end
      if t0 and count > 0 then
        log.dbg(
          'on_win %d: %d hunks [%d..%d] in %.2fms (viewport %d-%d)',
          bufnr,
          count,
          first,
          last,
          (vim.uv.hrtime() - t0) / 1e6,
          toprow,
          botrow
        )
      end
    end,
  })
end

return M
