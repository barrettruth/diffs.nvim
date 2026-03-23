require('spec.helpers')

local commands = require('diffs.commands')

describe('commands', function()
  describe('setup', function()
    it('registers Gdiff, Gvdiff, and Ghdiff commands', function()
      commands.setup()
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Gdiff)
      assert.is_not_nil(cmds.Gvdiff)
      assert.is_not_nil(cmds.Ghdiff)
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

  describe('filter_combined_diffs', function()
    it('strips diff --cc entries entirely', function()
      local lines = {
        'diff --cc main.lua',
        'index d13ab94,b113aee..0000000',
        '--- a/main.lua',
        '+++ b/main.lua',
        '@@@ -1,7 -1,7 +1,11 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        ' +  return 1',
        '++=======',
        '+   return 2',
        '++>>>>>>> theirs',
        '  end',
      }
      local result = commands.filter_combined_diffs(lines)
      assert.are.equal(0, #result)
    end)

    it('preserves diff --git entries', function()
      local lines = {
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,3 @@',
        ' local M = {}',
        '-local x = 1',
        '+local x = 2',
        ' return M',
      }
      local result = commands.filter_combined_diffs(lines)
      assert.are.equal(8, #result)
      assert.are.same(lines, result)
    end)

    it('strips combined but keeps unified in mixed output', function()
      local lines = {
        'diff --cc conflict.lua',
        'index aaa,bbb..000',
        '@@@ -1,1 -1,1 +1,5 @@@',
        '++<<<<<<< HEAD',
        'diff --git a/clean.lua b/clean.lua',
        '--- a/clean.lua',
        '+++ b/clean.lua',
        '@@ -1,1 +1,1 @@',
        '-old',
        '+new',
      }
      local result = commands.filter_combined_diffs(lines)
      assert.are.equal(6, #result)
      assert.are.equal('diff --git a/clean.lua b/clean.lua', result[1])
      assert.are.equal('+new', result[6])
    end)

    it('returns empty for empty input', function()
      local result = commands.filter_combined_diffs({})
      assert.are.equal(0, #result)
    end)

    it('returns empty when all entries are combined', function()
      local lines = {
        'diff --cc a.lua',
        'some content',
        'diff --cc b.lua',
        'more content',
      }
      local result = commands.filter_combined_diffs(lines)
      assert.are.equal(0, #result)
    end)
  end)

  describe('setup registers Greview command', function()
    it('registers Greview command', function()
      commands.setup()
      local cmds = vim.api.nvim_get_commands({})
      assert.is_not_nil(cmds.Greview)
    end)
  end)

  describe('review_file_at_line', function()
    local test_buffers = {}

    after_each(function()
      for _, bufnr in ipairs(test_buffers) do
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_delete(bufnr, { force = true })
        end
      end
      test_buffers = {}
    end)

    it('returns filename at cursor line', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'diff --git a/foo.lua b/foo.lua',
        '--- a/foo.lua',
        '+++ b/foo.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local x = 1',
        ' return M',
      })

      assert.are.equal('foo.lua', commands.review_file_at_line(bufnr, 6))
    end)

    it('returns correct file in multi-file diff', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'diff --git a/foo.lua b/foo.lua',
        '@@ -1 +1 @@',
        '-old',
        '+new',
        'diff --git a/bar.lua b/bar.lua',
        '@@ -1 +1 @@',
        '-old',
        '+new',
      })

      assert.are.equal('foo.lua', commands.review_file_at_line(bufnr, 3))
      assert.are.equal('bar.lua', commands.review_file_at_line(bufnr, 7))
    end)

    it('returns nil before any diff header', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'some preamble text',
        'diff --git a/foo.lua b/foo.lua',
      })

      assert.is_nil(commands.review_file_at_line(bufnr, 1))
    end)

    it('returns nil on empty buffer', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, bufnr)

      assert.is_nil(commands.review_file_at_line(bufnr, 1))
    end)
  end)

  describe('find_hunk_line', function()
    it('finds matching @@ header and returns target line', function()
      local diff_lines = {
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      }
      local hunk_position = {
        hunk_header = '@@ -1,3 +1,4 @@',
        offset = 2,
      }
      local target_line = commands.find_hunk_line(diff_lines, hunk_position)
      assert.equals(6, target_line)
    end)

    it('returns nil when hunk header not found', function()
      local diff_lines = {
        'diff --git a/file.lua b/file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
      }
      local hunk_position = {
        hunk_header = '@@ -99,3 +99,4 @@',
        offset = 1,
      }
      local target_line = commands.find_hunk_line(diff_lines, hunk_position)
      assert.is_nil(target_line)
    end)

    it('handles multiple hunks and finds correct one', function()
      local diff_lines = {
        'diff --git a/file.lua b/file.lua',
        '--- a/file.lua',
        '+++ b/file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local x = 1',
        ' ',
        '@@ -10,3 +11,4 @@',
        ' function M.foo()',
        '+  print("hello")',
        ' end',
      }
      local hunk_position = {
        hunk_header = '@@ -10,3 +11,4 @@',
        offset = 2,
      }
      local target_line = commands.find_hunk_line(diff_lines, hunk_position)
      assert.equals(10, target_line)
    end)
  end)
end)
