---@class diffs.DiffOpts
---@field algorithm? string
---@field linematch? integer

local M = {}

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
    end
  end
  return opts
end

--- Options to merge into a vim.diff()/vim.text.diff() call.
---@return diffs.DiffOpts
function M.vim_diff_opts()
  return M.resolve()
end

--- Equivalent git diff flags for the resolved options. linematch has no git
--- counterpart and is omitted.
---@return string[]
function M.git_flags()
  local opts = M.resolve()
  local flags = {}
  if opts.algorithm then
    flags[#flags + 1] = '--diff-algorithm=' .. opts.algorithm
  end
  return flags
end

return M
