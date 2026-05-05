---@class diffs.PublicApi
---@field attach fun(bufnr?: integer)
---@field refresh fun(bufnr?: integer)

local runtime = require('diffs.runtime')

---@type diffs.PublicApi
return {
  attach = runtime.attach,
  refresh = runtime.refresh,
}
