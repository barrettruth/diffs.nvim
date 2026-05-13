require('spec.helpers')

describe('plugin bootstrap', function()
  local function run_child_result(init_lines, after_lines)
    local tmpdir = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(tmpdir, 'p'))
    local init_file = tmpdir .. '/init.lua'
    local after_file = tmpdir .. '/after.lua'
    vim.fn.writefile(init_lines, init_file)
    vim.fn.writefile(after_lines or {}, after_file)

    local output = vim.fn.system({
      vim.v.progpath,
      '--headless',
      '--clean',
      '-u',
      init_file,
      '+luafile ' .. after_file,
      '+qa',
    })
    local shell_error = vim.v.shell_error
    vim.fn.delete(tmpdir, 'rf')
    return shell_error, output
  end

  local function run_child(init_lines, after_lines)
    local shell_error, output = run_child_result(init_lines, after_lines)
    assert.are.equal(0, shell_error, output)
    return output
  end

  it('loads supported config during plugin startup', function()
    local init_lines = {
      '_G.diffs_notifications = {}',
      'vim.notify = function(message, level)',
      '_G.diffs_notifications[#_G.diffs_notifications + 1] = { message = message, level = level }',
      'end',
      'vim.g.diffs = { view = { prefix = false }, highlights = { background = false }, conflict = { show_virtual_text = false }, integrations = { fugitive = true, neogit = true, neojj = true, gitsigns = true, committia = true, telescope = true } }',
      ('vim.opt.runtimepath:prepend(%s)'):format(vim.inspect(vim.fn.getcwd())),
    }

    local after_lines = {
      "print('loaded=' .. tostring(vim.g.loaded_diffs))",
      "print('notifications=' .. #(_G.diffs_notifications or {}))",
      "local runtime = require('diffs.runtime')",
      'runtime.attach(0)',
      "print('after_attach_notifications=' .. #(_G.diffs_notifications or {}))",
      'local runtime_config = runtime._test.get_config()',
      'local highlight_opts = runtime.get_highlight_opts()',
      "print('runtime_view_prefix=' .. tostring(runtime_config.view.prefix))",
      "print('runtime_fugitive=' .. tostring(runtime_config.integrations.fugitive))",
      "print('runtime_neogit=' .. tostring(runtime_config.integrations.neogit))",
      "print('runtime_neojj=' .. tostring(runtime_config.integrations.neojj))",
      "print('runtime_gitsigns=' .. tostring(runtime_config.integrations.gitsigns))",
      "print('runtime_committia=' .. tostring(runtime_config.integrations.committia))",
      "print('runtime_telescope=' .. tostring(runtime_config.integrations.telescope))",
      "print('runtime_background=' .. tostring(runtime_config.highlights.background))",
      "print('runtime_show_virtual_text=' .. tostring(runtime_config.conflict.show_virtual_text))",
      "print('runtime_config_priorities=' .. tostring(runtime_config.highlights.priorities))",
      "print('highlight_priority_clear=' .. tostring(highlight_opts.highlights.priorities.clear))",
      "print('highlight_priority_syntax=' .. tostring(highlight_opts.highlights.priorities.syntax))",
      "print('highlight_priority_line_bg=' .. tostring(highlight_opts.highlights.priorities.line_bg))",
      "print('highlight_priority_char_bg=' .. tostring(highlight_opts.highlights.priorities.char_bg))",
      'local has_fugitive = false',
      'local has_neogit = false',
      'local has_neojj = false',
      'local has_telescope = false',
      "for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'FileType' })) do",
      "if autocmd.pattern == 'fugitive' then has_fugitive = true end",
      "if autocmd.pattern == 'NeogitStatus' then has_neogit = true end",
      "if autocmd.pattern == 'NeojjStatus' then has_neojj = true end",
      'end',
      "for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'User' })) do",
      "if autocmd.pattern == 'TelescopePreviewerLoaded' then has_telescope = true end",
      'end',
      "print('has_fugitive_autocmd=' .. tostring(has_fugitive))",
      "print('has_neogit_autocmd=' .. tostring(has_neogit))",
      "print('has_neojj_autocmd=' .. tostring(has_neojj))",
      "print('has_telescope_autocmd=' .. tostring(has_telescope))",
    }

    local output = run_child(init_lines, after_lines)

    assert.matches('loaded=1', output, 1, true)
    assert.matches('notifications=0', output, 1, true)
    assert.matches('after_attach_notifications=0', output, 1, true)
    assert.matches('runtime_view_prefix=false', output, 1, true)
    assert.matches('runtime_fugitive=true', output, 1, true)
    assert.matches('runtime_neogit=true', output, 1, true)
    assert.matches('runtime_neojj=true', output, 1, true)
    assert.matches('runtime_gitsigns=true', output, 1, true)
    assert.matches('runtime_committia=true', output, 1, true)
    assert.matches('runtime_telescope=true', output, 1, true)
    assert.matches('runtime_background=false', output, 1, true)
    assert.matches('runtime_show_virtual_text=false', output, 1, true)
    assert.matches('runtime_config_priorities=nil', output, 1, true)
    assert.matches('highlight_priority_clear=198', output, 1, true)
    assert.matches('highlight_priority_syntax=199', output, 1, true)
    assert.matches('highlight_priority_line_bg=200', output, 1, true)
    assert.matches('highlight_priority_char_bg=201', output, 1, true)
    assert.matches('has_fugitive_autocmd=true', output, 1, true)
    assert.matches('has_neogit_autocmd=true', output, 1, true)
    assert.matches('has_neojj_autocmd=true', output, 1, true)
    assert.matches('has_telescope_autocmd=true', output, 1, true)
  end)

  it('rejects removed config during plugin startup', function()
    local init_lines = {
      'vim.g.diffs = { hide_prefix = true, highlights = { gutter = false, priorities = { syntax = 250 } }, conflict = { priority = 250 }, integrations = { fugitive = {} } }',
      ('vim.opt.runtimepath:prepend(%s)'):format(vim.inspect(vim.fn.getcwd())),
    }

    local shell_error, output = run_child_result(init_lines, {})

    assert.are.equal(0, shell_error)
    assert.matches('Error in ', output, 1, true)
    assert.matches('diffs: hide_prefix has been removed; use view.prefix', output, 1, true)
  end)
end)
