local M = {}

local message = table.concat({
  '[diffs.nvim] This repository will be removed from GitHub on October 31, 2026.',
  'Install from Forgejo: https://forge.barrettruth.com/barrettruth/diffs.nvim.',
  'See :help diffs-migration.',
}, ' ')

---@param origin unknown
---@return boolean
function M.is_github_origin(origin)
  if type(origin) ~= 'string' then
    return false
  end

  origin = origin:gsub('/+$', ''):gsub('%.git$', '')

  return origin == 'https://github.com/barrettruth/diffs.nvim'
    or origin == 'http://github.com/barrettruth/diffs.nvim'
    or origin == 'git://github.com/barrettruth/diffs.nvim'
    or origin == 'ssh://git@github.com/barrettruth/diffs.nvim'
    or origin == 'git@github.com:barrettruth/diffs.nvim'
end

---@return string
function M.plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source)))
end

---@param root string
---@param callback fun(origin: string)
function M.origin(root, callback)
  if vim.fn.executable('git') ~= 1 then
    return
  end

  local origin = ''
  pcall(vim.fn.jobstart, { 'git', '-C', root, 'config', '--get', 'remote.origin.url' }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      origin = table.concat(data, '\n')
    end,
    on_exit = function(_, code)
      if code == 0 then
        vim.schedule(function()
          callback(vim.trim(origin))
        end)
      end
    end,
  })
end

---@param root? string
function M.warn_if_github_source(root)
  M.origin(root or M.plugin_root(), function(origin)
    if M.is_github_origin(origin) then
      vim.notify_once(message, vim.log.levels.WARN)
    end
  end)
end

return M
