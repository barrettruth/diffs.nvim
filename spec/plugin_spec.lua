require('spec.helpers')

describe('plugin bootstrap', function()
  local function run_child(init_lines, after_lines)
    local tmpdir = vim.fn.tempname()
    assert.are.equal(1, vim.fn.mkdir(tmpdir, 'p'))
    local init_file = tmpdir .. '/init.lua'
    local after_file = tmpdir .. '/after.lua'
    vim.fn.writefile(init_lines, init_file)
    vim.fn.writefile(after_lines, after_file)

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
    assert.are.equal(0, shell_error, output)
    return output
  end

  it('emits config deprecations during plugin startup and not first attach', function()
    local init_lines = {
      '_G.diffs_notifications = {}',
      'vim.notify = function(message, level)',
      '_G.diffs_notifications[#_G.diffs_notifications + 1] = { message = message, level = level }',
      'end',
      "vim.g.diffs = { hide_prefix = true, highlights = { gutter = false }, conflict = { priority = 250 }, integrations = { fugitive = { horizontal = 'dd', vertical = false }, neogit = {}, neojj = {}, gitsigns = {} } }",
      ('vim.opt.runtimepath:prepend(%s)'):format(vim.inspect(vim.fn.getcwd())),
    }

    local after_lines = {
      'local function deprecations()',
      'local result = {}',
      'for _, item in ipairs(_G.diffs_notifications or {}) do',
      "if item.message:find('Feature will be removed', 1, true) then",
      "result[#result + 1] = item.message:gsub('\\n', ' | ')",
      'end',
      'end',
      'return result',
      'end',
      "print('loaded=' .. tostring(vim.g.loaded_diffs))",
      'local startup = deprecations()',
      "print('startup_deprecations=' .. #startup)",
      'for _, message in ipairs(startup) do print(message) end',
      "local runtime = require('diffs.runtime')",
      'runtime.attach(0)',
      "print('after_attach_deprecations=' .. #deprecations())",
      'local runtime_config = runtime._test.get_config()',
      "print('runtime_view_prefix=' .. tostring(runtime_config.view.prefix))",
      "print('runtime_fugitive_horizontal=' .. tostring(runtime_config.integrations.fugitive.horizontal))",
      "print('runtime_neogit=' .. tostring(runtime_config.integrations.neogit))",
      "print('runtime_neojj=' .. tostring(runtime_config.integrations.neojj))",
      "print('runtime_gitsigns=' .. tostring(runtime_config.integrations.gitsigns))",
      "print('runtime_gutter=' .. tostring(runtime_config.highlights.gutter))",
      "print('runtime_conflict_priority=' .. tostring(runtime_config.conflict.priority))",
      'local has_fugitive = false',
      'local has_neogit = false',
      'local has_neojj = false',
      "for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'FileType' })) do",
      "if autocmd.pattern == 'fugitive' then has_fugitive = true end",
      "if autocmd.pattern == 'NeogitStatus' then has_neogit = true end",
      "if autocmd.pattern == 'NeojjStatus' then has_neojj = true end",
      'end',
      "print('has_fugitive_autocmd=' .. tostring(has_fugitive))",
      "print('has_neogit_autocmd=' .. tostring(has_neogit))",
      "print('has_neojj_autocmd=' .. tostring(has_neojj))",
    }

    local output = run_child(init_lines, after_lines)

    assert.matches('loaded=1', output, 1, true)
    assert.matches('startup_deprecations=7', output, 1, true)
    assert.matches(
      'vim.g.diffs.hide_prefix is deprecated, use vim.g.diffs.view.prefix instead. | Feature will be removed in diffs.nvim 0.4.0',
      output,
      1,
      true
    )
    assert.matches(
      'vim.g.diffs.integrations.fugitive.{horizontal,vertical} is deprecated. | Feature will be removed in diffs.nvim 0.4.0',
      output,
      1,
      true
    )
    assert.matches(
      'vim.g.diffs.integrations.neogit = { ... } is deprecated, use vim.g.diffs.integrations.neogit = true instead. | Feature will be removed in diffs.nvim 0.4.0',
      output,
      1,
      true
    )
    assert.matches(
      'vim.g.diffs.integrations.neojj = { ... } is deprecated, use vim.g.diffs.integrations.neojj = true instead. | Feature will be removed in diffs.nvim 0.4.0',
      output,
      1,
      true
    )
    assert.matches(
      'vim.g.diffs.integrations.gitsigns = { ... } is deprecated, use vim.g.diffs.integrations.gitsigns = true instead. | Feature will be removed in diffs.nvim 0.4.0',
      output,
      1,
      true
    )
    assert.matches(
      'vim.g.diffs.highlights.gutter is deprecated. | Feature will be removed in diffs.nvim 0.4.0',
      output,
      1,
      true
    )
    assert.matches(
      'vim.g.diffs.conflict.priority is deprecated. | Feature will be removed in diffs.nvim 0.4.0',
      output,
      1,
      true
    )
    assert.matches('after_attach_deprecations=7', output, 1, true)
    assert.matches('runtime_view_prefix=false', output, 1, true)
    assert.matches('runtime_fugitive_horizontal=nil', output, 1, true)
    assert.matches('runtime_neogit=true', output, 1, true)
    assert.matches('runtime_neojj=true', output, 1, true)
    assert.matches('runtime_gitsigns=true', output, 1, true)
    assert.matches('runtime_gutter=false', output, 1, true)
    assert.matches('runtime_conflict_priority=nil', output, 1, true)
    assert.matches('has_fugitive_autocmd=true', output, 1, true)
    assert.matches('has_neogit_autocmd=true', output, 1, true)
    assert.matches('has_neojj_autocmd=true', output, 1, true)
  end)
end)
