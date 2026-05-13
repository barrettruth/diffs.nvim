local helpers = require('spec.helpers')
local runtime = require('diffs.runtime')
local telescope = require('diffs.telescope')

describe('diffs.telescope', function()
  local saved_attach

  before_each(function()
    saved_attach = runtime.attach
    pcall(vim.api.nvim_del_augroup_by_name, 'diffs_telescope')
  end)

  after_each(function()
    runtime.attach = saved_attach
    pcall(vim.api.nvim_del_augroup_by_name, 'diffs_telescope')
  end)

  it('attaches the current Telescope preview buffer when the preview event fires', function()
    local bufnr = helpers.create_buffer({
      'diff --git a/file.lua b/file.lua',
      '@@ -1 +1 @@',
      '-old',
      '+new',
    })
    local previous = vim.api.nvim_get_current_buf()
    local attached_bufnr

    runtime.attach = function(target)
      attached_bufnr = target
    end

    telescope.setup()
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_exec_autocmds('User', { pattern = 'TelescopePreviewerLoaded' })
    if vim.api.nvim_buf_is_valid(previous) then
      vim.api.nvim_set_current_buf(previous)
    end
    helpers.delete_buffer(bufnr)

    assert.are.equal(bufnr, attached_bufnr)
  end)
end)
