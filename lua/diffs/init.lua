---@class diffs.PublicApi
---@field attach fun(bufnr?: integer, options?: diffs.AttachOptions)
---@field detach fun(bufnr?: integer)
---@field highlight_options fun(): diffs.HunkOpts
---@field diff_options fun(): diffs.DiffOpts
---@field compute_intra_hunks fun(lines: string[]): diffs.IntraChanges?
---@field whitespace_only_lines fun(lines: string[]): table<integer, true>
---@field open_review fun(spec?: diffs.ReviewSpec, opts?: diffs.ReviewOpts): integer?
---@field refresh fun(bufnr?: integer)
---@field review_files fun(bufnr?: integer): diffs.ReviewFile[]?
---@field review_current fun(bufnr?: integer): { index: integer, count: integer, file: diffs.ReviewFile }?
---@field review_goto fun(target: string, bufnr?: integer): boolean
---@field review_next_file fun()
---@field review_prev_file fun()
---@field review_toggle_layout fun(opts?: diffs.ReviewToggleLayoutOpts): integer?
---@field select_review_file fun(bufnr?: integer)

local runtime = require('diffs.runtime')

local function command(name)
  return function(...)
    return require('diffs.commands')[name](...)
  end
end

---@type diffs.PublicApi
return {
  attach = runtime.attach,
  detach = runtime.detach,
  highlight_options = runtime.get_highlight_opts,
  diff_options = require('diffs.diffopt').resolve,
  compute_intra_hunks = require('diffs.diff').compute_intra_hunks,
  whitespace_only_lines = require('diffs.diff').whitespace_only_lines,
  open_review = command('open_review'),
  refresh = runtime.refresh,
  review_files = command('review_files'),
  review_current = command('review_current'),
  review_goto = command('review_goto'),
  review_next_file = command('review_next_file'),
  review_prev_file = command('review_prev_file'),
  review_toggle_layout = command('review_toggle_layout'),
  select_review_file = command('select_review_file'),
}
