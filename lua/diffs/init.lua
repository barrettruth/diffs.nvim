---@class diffs
---@field attach fun(bufnr?: integer)
---@field refresh fun(bufnr?: integer)
local M = {}

local runtime = require('diffs.runtime')

M.attach = runtime.attach
M.refresh = runtime.refresh
M.attach_diff = runtime.attach_diff
M.detach_diff = runtime.detach_diff

M.is_fugitive_buffer = runtime.is_fugitive_buffer
M.compute_filetypes = runtime.compute_filetypes

M.get_fugitive_config = runtime.get_fugitive_config
M.get_neojj_config = runtime.get_neojj_config
M.get_committia_config = runtime.get_committia_config
M.get_telescope_config = runtime.get_telescope_config
M.get_conflict_config = runtime.get_conflict_config
M.get_highlight_opts = runtime.get_highlight_opts

M._test = runtime._test

return M
