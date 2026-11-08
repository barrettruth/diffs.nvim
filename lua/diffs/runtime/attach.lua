local integrations = require('diffs.integrations')
local log = require('diffs.log')

local M = {}

---@class diffs.AttachOpts
---@field cache diffs.Cache
---@field attached_buffers table<integer, boolean>
---@field get_config fun(): diffs.Config
---@field refresh fun(bufnr?: integer)

---@param opts diffs.AttachOpts
---@param bufnr? integer
function M.attach(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  if opts.attached_buffers[bufnr] then
    return
  end
  opts.attached_buffers[bufnr] = true

  local config = opts.get_config()
  local integration_augroup
  for key, event in pairs({ neogit = 'NeogitDiffLoaded', neojj = 'NeojjDiffLoaded' }) do
    if
      integrations.is_enabled(config.integrations[key])
      and integrations.matches_filetype(key, vim.bo[bufnr].filetype)
    then
      vim.b[bufnr][key .. '_disable_hunk_highlight'] = true
      integration_augroup =
        vim.api.nvim_create_augroup('diffs_' .. key .. '_' .. bufnr, { clear = true })
      vim.api.nvim_create_autocmd('User', {
        pattern = event,
        group = integration_augroup,
        callback = function()
          if vim.api.nvim_buf_is_valid(bufnr) and opts.attached_buffers[bufnr] then
            opts.refresh(bufnr)
          end
        end,
      })
      break
    end
  end

  log.dbg('attaching to buffer %d', bufnr)

  opts.cache:ensure(bufnr)

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      opts.attached_buffers[bufnr] = nil
      opts.cache:delete(bufnr)
      if integration_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, integration_augroup)
      end
    end,
  })
end

return M
