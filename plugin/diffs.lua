if vim.g.loaded_diffs then
  return
end

local config = require('diffs.config')
local integrations = require('diffs.integrations')
local user_config = config.new(vim.deepcopy(vim.g.diffs or {}))

vim.g.loaded_diffs = 1

local function get_runtime()
  local runtime = require('diffs.runtime')
  runtime.configure(user_config)
  return runtime
end

local integration_config = user_config.integrations or {}

if integrations.is_enabled(integration_config.gitsigns) then
  if package.loaded.gitsigns then
    require('diffs.gitsigns').setup()
  else
    vim.api.nvim_create_autocmd('User', {
      pattern = 'GitAttach',
      once = true,
      callback = function()
        require('diffs.gitsigns').setup()
      end,
    })
  end
end

if integrations.is_enabled(integration_config.telescope) then
  require('diffs.telescope').setup(function(bufnr)
    get_runtime().attach(bufnr)
  end)
end

vim.api.nvim_create_autocmd('FileType', {
  pattern = config.compute_filetypes(user_config),
  callback = function(args)
    local runtime = get_runtime()
    runtime.attach(args.buf)
  end,
})

vim.api.nvim_create_autocmd('OptionSet', {
  pattern = 'diff',
  callback = function()
    local runtime = get_runtime()
    if vim.wo.diff then
      runtime.attach_diff()
    else
      runtime.detach_diff()
    end
  end,
})

vim.api.nvim_create_autocmd('VimEnter', {
  callback = function()
    if vim.wo.diff then
      get_runtime().attach_diff()
    end
  end,
})

vim.api.nvim_create_autocmd('OptionSet', {
  pattern = 'diffopt',
  callback = function()
    get_runtime().invalidate_attached()
    vim.cmd('redraw!')
  end,
})
