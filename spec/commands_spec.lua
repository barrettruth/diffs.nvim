require('spec.helpers')

describe('commands', function()
  describe('setup', function()
    it('registers Gdiff, Gvdiff, and Ghdiff commands', function()
      require('diffs.commands').setup()
      local commands = vim.api.nvim_get_commands({})
      assert.is_not_nil(commands.Gdiff)
      assert.is_not_nil(commands.Gvdiff)
      assert.is_not_nil(commands.Ghdiff)
    end)
  end)

  describe('unified diff generation', function()
    local old_lines = { 'local M = {}', 'return M' }
    local new_lines = { 'local M = {}', 'local x = 1', 'return M' }
    local diff_fn = vim.text and vim.text.diff or vim.diff

    it('generates valid unified diff', function()
      local old_content = table.concat(old_lines, '\n')
      local new_content = table.concat(new_lines, '\n')
      local diff_output = diff_fn(old_content, new_content, {
        result_type = 'unified',
        ctxlen = 3,
      })
      assert.is_not_nil(diff_output)
      assert.is_true(diff_output:find('@@ ') ~= nil)
      assert.is_true(diff_output:find('+local x = 1') ~= nil)
    end)

    it('returns empty for identical content', function()
      local content = table.concat(old_lines, '\n')
      local diff_output = diff_fn(content, content, {
        result_type = 'unified',
        ctxlen = 3,
      })
      assert.are.equal('', diff_output)
    end)
  end)
end)
