---@class diffs.PublicApi
---@field attach fun(bufnr?: integer)
---@field refresh fun(bufnr?: integer)
---@field review_files fun(bufnr?: integer): diffs.ReviewFile[]?
---@field review_current fun(bufnr?: integer): { index: integer, count: integer, file: diffs.ReviewFile }?
---@field review_goto fun(target: string, bufnr?: integer): boolean
---@field review_next_file fun()
---@field review_prev_file fun()
---@field select_review_file fun(bufnr?: integer)

local commands = require('diffs.commands')
local runtime = require('diffs.runtime')

---@type diffs.PublicApi
return {
  attach = runtime.attach,
  refresh = runtime.refresh,
  review_files = commands.review_files,
  review_current = commands.review_current,
  review_goto = commands.review_goto,
  review_next_file = commands.review_next_file,
  review_prev_file = commands.review_prev_file,
  select_review_file = commands.select_review_file,
}
