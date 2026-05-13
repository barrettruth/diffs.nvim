local M = {}

function M.setup()
  local runtime = require('diffs.runtime')
  local group = vim.api.nvim_create_augroup('diffs_telescope', { clear = true })
  return vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'TelescopePreviewerLoaded',
    callback = function()
      runtime.attach(vim.api.nvim_get_current_buf())
    end,
  })
end

return M
