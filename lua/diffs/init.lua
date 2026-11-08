---@class diffs.PublicApi
---@field attach fun(bufnr?: integer)
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
