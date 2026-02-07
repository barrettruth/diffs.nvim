local plugin_dir = vim.fn.getcwd()
vim.opt.runtimepath:prepend(plugin_dir)
vim.opt.packpath = {}

vim.cmd('filetype on')

local function ensure_parser(lang)
  local ok = pcall(vim.treesitter.language.inspect, lang)
  if not ok then
    error('Treesitter parser for ' .. lang .. ' not available. Neovim 0.10+ bundles lua parser.')
  end
end

ensure_parser('lua')
ensure_parser('vim')

local M = {}

function M.create_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  return bufnr
end

function M.delete_buffer(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

function M.get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

return M
