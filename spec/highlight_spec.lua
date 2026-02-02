require('spec.helpers')
local highlight = require('fugitive-ts.highlight')

describe('highlight', function()
  describe('highlight_hunk', function()
    local ns

    before_each(function()
      ns = vim.api.nvim_create_namespace('fugitive_ts_test')
    end)

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

    local function get_extmarks(bufnr)
      return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    end

    it('applies extmarks for lua code', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, 500, false, false)

      local extmarks = get_extmarks(bufnr)
      assert.is_true(#extmarks > 0)
      delete_buffer(bufnr)
    end)

    it('applies Normal extmarks to clear diff colors', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, 500, false, false)

      local extmarks = get_extmarks(bufnr)
      local has_normal = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'Normal' then
          has_normal = true
          break
        end
      end
      assert.is_true(has_normal)
      delete_buffer(bufnr)
    end)

    it('skips hunks larger than max_lines', function()
      local lines = { '@@ -1,100 +1,101 @@' }
      local hunk_lines = {}
      for i = 1, 600 do
        table.insert(lines, ' line ' .. i)
        table.insert(hunk_lines, ' line ' .. i)
      end

      local bufnr = create_buffer(lines)
      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = hunk_lines,
      }

      highlight.highlight_hunk(bufnr, ns, hunk, 500, false, false)

      local extmarks = get_extmarks(bufnr)
      assert.are.equal(0, #extmarks)
      delete_buffer(bufnr)
    end)

    it('does nothing for nil lang', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' some content',
        '+more content',
      })

      local hunk = {
        filename = 'test.unknown',
        lang = nil,
        start_line = 1,
        lines = { ' some content', '+more content' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, 500, false, false)

      local extmarks = get_extmarks(bufnr)
      assert.are.equal(0, #extmarks)
      delete_buffer(bufnr)
    end)

    it('highlights header context when enabled', function()
      local bufnr = create_buffer({
        '@@ -10,3 +10,4 @@ function hello()',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        header_context = 'function hello()',
        header_context_col = 18,
        lines = { ' local x = 1', '+local y = 2' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, 500, true, false)

      local extmarks = get_extmarks(bufnr)
      local has_header_extmark = false
      for _, mark in ipairs(extmarks) do
        if mark[2] == 0 then
          has_header_extmark = true
          break
        end
      end
      assert.is_true(has_header_extmark)
      delete_buffer(bufnr)
    end)

    it('does not highlight header when disabled', function()
      local bufnr = create_buffer({
        '@@ -10,3 +10,4 @@ function hello()',
        ' local x = 1',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        header_context = 'function hello()',
        header_context_col = 18,
        lines = { ' local x = 1' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, 500, false, false)

      local extmarks = get_extmarks(bufnr)
      local header_extmarks = 0
      for _, mark in ipairs(extmarks) do
        if mark[2] == 0 then
          header_extmarks = header_extmarks + 1
        end
      end
      assert.are.equal(0, header_extmarks)
      delete_buffer(bufnr)
    end)

    it('handles empty hunk lines', function()
      local bufnr = create_buffer({
        '@@ -1,0 +1,0 @@',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = {},
      }

      assert.has_no.errors(function()
        highlight.highlight_hunk(bufnr, ns, hunk, 500, false, false)
      end)
      delete_buffer(bufnr)
    end)

    it('handles code that is just whitespace', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' ',
        '+  ',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' ', '+  ' },
      }

      assert.has_no.errors(function()
        highlight.highlight_hunk(bufnr, ns, hunk, 500, false, false)
      end)
      delete_buffer(bufnr)
    end)
  end)
end)
