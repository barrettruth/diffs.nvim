local integrations = require('diffs.integrations')

local M = {}

---@class diffs.AttachOptions
---@field hunks? fun(bufnr: integer): diffs.Hunk[]
---@field intra? boolean

---@class diffs.Attachment: diffs.AttachOptions
---@field augroup integer

---@class diffs.DetachOpts
---@field cache diffs.Cache
---@field attached_buffers table<integer, diffs.Attachment>

---@class diffs.AttachOpts: diffs.DetachOpts
---@field get_config fun(): diffs.Config
---@field refresh fun(bufnr?: integer)

---@param opts diffs.DetachOpts
---@param bufnr? integer
function M.detach(opts, bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local attachment = opts.attached_buffers[bufnr]
  if not attachment then
    return
  end
  opts.attached_buffers[bufnr] = nil
  opts.cache:delete(bufnr)
  vim.api.nvim_del_augroup_by_id(attachment.augroup)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, opts.cache.ns, 0, -1)
  end
end

---@param opts diffs.AttachOpts
---@param bufnr? integer
---@param options? diffs.AttachOptions
function M.attach(opts, bufnr, options)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if opts.attached_buffers[bufnr] then
    if not options then
      return
    end
    M.detach(opts, bufnr)
  end
  local attachment = {
    hunks = options and options.hunks,
    intra = options and options.intra,
    augroup = vim.api.nvim_create_augroup('diffs_buffer_' .. bufnr, { clear = true }),
  }
  opts.attached_buffers[bufnr] = attachment
  local config = opts.get_config()
  for name, event in pairs({ neogit = 'NeogitDiffLoaded', neojj = 'NeojjDiffLoaded' }) do
    if
      integrations.is_enabled(config.integrations[name])
      and integrations.matches_filetype(name, vim.bo[bufnr].filetype)
    then
      vim.b[bufnr][name .. '_disable_hunk_highlight'] = true
      vim.api.nvim_create_autocmd('User', {
        pattern = event,
        group = attachment.augroup,
        callback = function()
          if vim.api.nvim_buf_is_valid(bufnr) and opts.attached_buffers[bufnr] == attachment then
            opts.refresh(bufnr)
          end
        end,
      })
      break
    end
  end
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    group = attachment.augroup,
    callback = function()
      if opts.attached_buffers[bufnr] == attachment then
        M.detach(opts, bufnr)
      end
    end,
  })
  opts.cache:ensure(bufnr)
end

return M
