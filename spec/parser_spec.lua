require('spec.helpers')
local parser = require('diffs.parser')

describe('parser', function()
  describe('parse_buffer', function()
    local function create_buffer(lines)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      return bufnr
    end

    local function delete_buffer(bufnr)
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end

    it('returns empty table for empty buffer', function()
      local bufnr = create_buffer({})
      local hunks = parser.parse_buffer(bufnr)
      assert.are.same({}, hunks)
      delete_buffer(bufnr)
    end)

    it('returns empty table for buffer with no hunks', function()
      local bufnr = create_buffer({
        'Head: main',
        'Help: g?',
        '',
        'Unstaged (1)',
        'M lua/test.lua',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.same({}, hunks)
      delete_buffer(bufnr)
    end)

    it('detects single hunk with lua file', function()
      local bufnr = create_buffer({
        'Unstaged (1)',
        'M lua/test.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('lua/test.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].ft)
      assert.are.equal('lua', hunks[1].lang)
      assert.are.equal(3, hunks[1].start_line)
      assert.are.equal(3, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('detects multiple hunks in same file', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -1,2 +1,2 @@',
        ' local M = {}',
        '-local old = false',
        '+local new = true',
        '@@ -10,2 +10,3 @@',
        ' function M.foo()',
        '+  print("hello")',
        ' end',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(2, #hunks)
      assert.are.equal(2, hunks[1].start_line)
      assert.are.equal(6, hunks[2].start_line)
      delete_buffer(bufnr)
    end)

    it('detects hunks across multiple files', function()
      local orig_get_lang = vim.treesitter.language.get_lang
      local orig_inspect = vim.treesitter.language.inspect
      vim.treesitter.language.get_lang = function(ft)
        local result = orig_get_lang(ft)
        if result then
          return result
        end
        if ft == 'python' then
          return 'python'
        end
        return nil
      end
      vim.treesitter.language.inspect = function(lang)
        if lang == 'python' then
          return {}
        end
        return orig_inspect(lang)
      end

      local bufnr = create_buffer({
        'M lua/foo.lua',
        '@@ -1,1 +1,2 @@',
        ' local M = {}',
        '+local x = 1',
        'M src/bar.py',
        '@@ -1,1 +1,2 @@',
        ' def hello():',
        '+    pass',
      })
      local hunks = parser.parse_buffer(bufnr)

      vim.treesitter.language.get_lang = orig_get_lang
      vim.treesitter.language.inspect = orig_inspect

      assert.are.equal(2, #hunks)
      assert.are.equal('lua/foo.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].lang)
      assert.are.equal('src/bar.py', hunks[2].filename)
      assert.are.equal('python', hunks[2].lang)
      delete_buffer(bufnr)
    end)

    it('extracts header context', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -10,3 +10,4 @@ function M.hello()',
        ' local msg = "hi"',
        '+print(msg)',
        ' end',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('function M.hello()', hunks[1].header_context)
      assert.is_not_nil(hunks[1].header_context_col)
      delete_buffer(bufnr)
    end)

    it('handles header without context', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.is_nil(hunks[1].header_context)
      delete_buffer(bufnr)
    end)

    it('handles all git status prefixes', function()
      local prefixes = { 'M', 'A', 'D', 'R', 'C', '?', '!' }
      for _, prefix in ipairs(prefixes) do
        local bufnr = create_buffer({
          prefix .. ' test.lua',
          '@@ -1,1 +1,2 @@',
          ' local x = 1',
          '+local y = 2',
        })
        local hunks = parser.parse_buffer(bufnr)
        assert.are.equal(1, #hunks, 'Failed for prefix: ' .. prefix)
        delete_buffer(bufnr)
      end
    end)

    it('stops hunk at blank line', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        '+local y = 2',
        '',
        'Some other content',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(2, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('emits hunk with ft when no ts parser available', function()
      local bufnr = create_buffer({
        'M test.xyz_no_parser',
        '@@ -1,1 +1,2 @@',
        ' some content',
        '+more content',
      })

      vim.filetype.add({ extension = { xyz_no_parser = 'xyz_no_parser_ft' } })

      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('xyz_no_parser_ft', hunks[1].ft)
      assert.is_nil(hunks[1].lang)
      assert.are.equal(2, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('stops hunk at next file header', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        '+local y = 2',
        'M other.lua',
        '@@ -1,1 +1,1 @@',
        ' local z = 3',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(2, #hunks)
      assert.are.equal(2, #hunks[1].lines)
      assert.are.equal(1, #hunks[2].lines)
      delete_buffer(bufnr)
    end)

    it('attaches header_lines to first hunk only', function()
      local bufnr = create_buffer({
        'diff --git a/parser.lua b/parser.lua',
        'index 3e8afa0..018159c 100644',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
        '@@ -10,2 +11,3 @@',
        ' function M.foo()',
        '+  return true',
        ' end',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(2, #hunks)
      assert.is_not_nil(hunks[1].header_start_line)
      assert.is_not_nil(hunks[1].header_lines)
      assert.are.equal(1, hunks[1].header_start_line)
      assert.is_nil(hunks[2].header_start_line)
      assert.is_nil(hunks[2].header_lines)
      delete_buffer(bufnr)
    end)

    it('header_lines contains only diff metadata, not hunk content', function()
      local bufnr = create_buffer({
        'diff --git a/parser.lua b/parser.lua',
        'index 3e8afa0..018159c 100644',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(4, #hunks[1].header_lines)
      assert.are.equal('diff --git a/parser.lua b/parser.lua', hunks[1].header_lines[1])
      assert.are.equal('index 3e8afa0..018159c 100644', hunks[1].header_lines[2])
      assert.are.equal('--- a/parser.lua', hunks[1].header_lines[3])
      assert.are.equal('+++ b/parser.lua', hunks[1].header_lines[4])
      delete_buffer(bufnr)
    end)

    it('handles fugitive status format with diff headers', function()
      local bufnr = create_buffer({
        'Head: main',
        'Push: origin/main',
        '',
        'Unstaged (1)',
        'M parser.lua',
        'diff --git a/parser.lua b/parser.lua',
        'index 3e8afa0..018159c 100644',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(6, hunks[1].header_start_line)
      assert.are.equal(4, #hunks[1].header_lines)
      assert.are.equal('diff --git a/parser.lua b/parser.lua', hunks[1].header_lines[1])
      delete_buffer(bufnr)
    end)
  end)
end)
