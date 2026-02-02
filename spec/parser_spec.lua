require('spec.helpers')
local parser = require('fugitive-ts.parser')

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

    local test_langs = {
      ['lua/test.lua'] = 'lua',
      ['lua/foo.lua'] = 'lua',
      ['src/bar.py'] = 'python',
      ['test.lua'] = 'lua',
      ['test.py'] = 'python',
      ['other.lua'] = 'lua',
      ['.envrc'] = 'bash',
    }

    it('returns empty table for empty buffer', function()
      local bufnr = create_buffer({})
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)
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
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)
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
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)

      assert.are.equal(1, #hunks)
      assert.are.equal('lua/test.lua', hunks[1].filename)
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
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)

      assert.are.equal(2, #hunks)
      assert.are.equal(2, hunks[1].start_line)
      assert.are.equal(6, hunks[2].start_line)
      delete_buffer(bufnr)
    end)

    it('detects hunks across multiple files', function()
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
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)

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
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)

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
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)

      assert.are.equal(1, #hunks)
      assert.is_nil(hunks[1].header_context)
      delete_buffer(bufnr)
    end)

    it('respects custom language mappings', function()
      local bufnr = create_buffer({
        'M .envrc',
        '@@ -1,1 +1,2 @@',
        ' export FOO=bar',
        '+export BAZ=qux',
      })
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)

      assert.are.equal(1, #hunks)
      assert.are.equal('bash', hunks[1].lang)
      delete_buffer(bufnr)
    end)

    it('respects disabled_languages', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local M = {}',
        '+local x = 1',
        'M test.py',
        '@@ -1,1 +1,2 @@',
        ' def foo():',
        '+    pass',
      })
      local hunks = parser.parse_buffer(bufnr, test_langs, { 'lua' }, false)

      assert.are.equal(1, #hunks)
      assert.are.equal('test.py', hunks[1].filename)
      assert.are.equal('python', hunks[1].lang)
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
        local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)
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
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)

      assert.are.equal(1, #hunks)
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
      local hunks = parser.parse_buffer(bufnr, test_langs, {}, false)

      assert.are.equal(2, #hunks)
      assert.are.equal(2, #hunks[1].lines)
      assert.are.equal(1, #hunks[2].lines)
      delete_buffer(bufnr)
    end)
  end)
end)
