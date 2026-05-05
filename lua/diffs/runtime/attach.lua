local log = require('diffs.log')

local M = {}

---@class diffs.AttachOpts
---@field cache diffs.Cache
---@field attached_buffers table<integer, boolean>
---@field get_config fun(): diffs.Config
---@field refresh fun(bufnr?: integer)

---@param bufnr integer
---@return boolean
function M.is_fugitive_buffer(bufnr)
  return vim.api.nvim_buf_get_name(bufnr):match('^fugitive://') ~= nil
end

---@param opts diffs.AttachOpts
---@param bufnr? integer
function M.attach(opts, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if opts.attached_buffers[bufnr] then
    return
  end
  opts.attached_buffers[bufnr] = true

  local config = opts.get_config()
  local neogit_augroup = nil
  if config.integrations.neogit and vim.bo[bufnr].filetype:match('^Neogit') then
    vim.b[bufnr].neogit_disable_hunk_highlight = true
    neogit_augroup = vim.api.nvim_create_augroup('diffs_neogit_' .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd('User', {
      pattern = 'NeogitDiffLoaded',
      group = neogit_augroup,
      callback = function()
        if vim.api.nvim_buf_is_valid(bufnr) and opts.attached_buffers[bufnr] then
          opts.refresh(bufnr)
        end
      end,
    })
  end

  local neojj_augroup = nil
  if config.integrations.neojj and vim.bo[bufnr].filetype:match('^Neojj') then
    vim.b[bufnr].neojj_disable_hunk_highlight = true
    neojj_augroup = vim.api.nvim_create_augroup('diffs_neojj_' .. bufnr, { clear = true })
    vim.api.nvim_create_autocmd('User', {
      pattern = 'NeojjDiffLoaded',
      group = neojj_augroup,
      callback = function()
        if vim.api.nvim_buf_is_valid(bufnr) and opts.attached_buffers[bufnr] then
          opts.refresh(bufnr)
        end
      end,
    })
  end

  log.dbg('attaching to buffer %d', bufnr)

  opts.cache:ensure(bufnr)

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    callback = function()
      opts.attached_buffers[bufnr] = nil
      opts.cache:delete(bufnr)
      if neogit_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, neogit_augroup)
      end
      if neojj_augroup then
        pcall(vim.api.nvim_del_augroup_by_id, neojj_augroup)
      end
    end,
  })
end

return M
