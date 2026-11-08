---@alias diffs.InlineMode 'none'|'simple'|'char'|'word'

---@class diffs.DiffOpts
---@field algorithm? string
---@field linematch? integer
---@field inline? diffs.InlineMode
---@field ignore_whitespace? boolean
---@field ignore_whitespace_change? boolean
---@field ignore_whitespace_change_at_eol? boolean
---@field ignore_blank_lines? boolean

local M = {}

--- 'diffopt' whitespace flags mapped onto vim.diff() option names. Both engines
--- are xdiff, so the names line up: iwhite -> -b, iwhiteall -> -w.
---@type table<string, string>
local WHITESPACE_FLAGS = {
  iwhite = 'ignore_whitespace_change',
  iwhiteall = 'ignore_whitespace',
  iwhiteeol = 'ignore_whitespace_change_at_eol',
  iblank = 'ignore_blank_lines',
}

--- 'diffopt' inline: granularities. Unknown values are ignored rather than
--- treated as "off", so a value added by a future Neovim does not silently
--- drop intra-line highlighting.
---@type table<string, boolean>
local INLINE_MODES = {
  none = true,
  simple = true,
  char = true,
  word = true,
}

--- Resolve the effective diff options from Neovim's global 'diffopt'.
---@return diffs.DiffOpts
function M.resolve()
  ---@type diffs.DiffOpts
  local opts = {}
  for _, item in ipairs(vim.split(vim.o.diffopt, ',', { plain = true })) do
    local key, val = item:match('^(%w+):(.+)$')
    if key == 'algorithm' then
      opts.algorithm = val
    elseif key == 'linematch' then
      opts.linematch = tonumber(val)
    elseif key == 'inline' and INLINE_MODES[val] then
      opts.inline = val
    elseif WHITESPACE_FLAGS[item] then
      opts[WHITESPACE_FLAGS[item]] = true
    end
  end
  return opts
end

--- Effective intra-line granularity. 'diffopt' treats a missing `inline:` as
--- `simple`, so plugin surfaces resolve it the same way native diff windows do.
---@return diffs.InlineMode
function M.inline()
  return M.resolve().inline or 'simple'
end

--- Options to merge into a vim.diff()/vim.text.diff() call. inline is dropped:
--- it only shapes highlighting, and vim.diff() rejects keys it does not know.
---@return diffs.DiffOpts
function M.vim_diff_opts()
  local opts = M.resolve()
  opts.inline = nil
  return opts
end

return M
