require('spec.helpers')
local highlight = require('diffs.highlight')

describe('highlight', function()
  describe('highlight_hunk', function()
    local ns

    before_each(function()
      ns = vim.api.nvim_create_namespace('diffs_test')
      local diff_add = vim.api.nvim_get_hl(0, { name = 'DiffAdd' })
      local diff_delete = vim.api.nvim_get_hl(0, { name = 'DiffDelete' })
      vim.api.nvim_set_hl(0, 'DiffsAdd', { bg = diff_add.bg })
      vim.api.nvim_set_hl(0, 'DiffsDelete', { bg = diff_delete.bg })
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

    local function default_opts(overrides)
      local opts = {
        hide_prefix = false,
        highlights = {
          background = false,
          gutter = false,
          treesitter = {
            enabled = true,
            max_lines = 500,
          },
          vim = {
            enabled = false,
            max_lines = 200,
          },
        },
      }
      if overrides then
        if overrides.highlights then
          opts.highlights = vim.tbl_deep_extend('force', opts.highlights, overrides.highlights)
        end
        if overrides.hide_prefix ~= nil then
          opts.hide_prefix = overrides.hide_prefix
        end
      end
      return opts
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

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

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

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

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

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      assert.are.equal(0, #extmarks)
      delete_buffer(bufnr)
    end)

    it('does nothing for nil lang and nil ft', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' some content',
        '+more content',
      })

      local hunk = {
        filename = 'test.unknown',
        ft = nil,
        lang = nil,
        start_line = 1,
        lines = { ' some content', '+more content' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

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

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

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

    it('does not highlight header when no header_context', function()
      local bufnr = create_buffer({
        '@@ -10,3 +10,4 @@',
        ' local x = 1',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

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
        highlight.highlight_hunk(bufnr, ns, hunk, default_opts())
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
        highlight.highlight_hunk(bufnr, ns, hunk, default_opts())
      end)
      delete_buffer(bufnr)
    end)

    it('applies overlay extmarks when hide_prefix enabled', function()
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

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts({ hide_prefix = true }))

      local extmarks = get_extmarks(bufnr)
      local overlay_count = 0
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text_pos == 'overlay' then
          overlay_count = overlay_count + 1
        end
      end
      assert.are.equal(2, overlay_count)
      delete_buffer(bufnr)
    end)

    it('does not apply overlay extmarks when hide_prefix disabled', function()
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

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts({ hide_prefix = false }))

      local extmarks = get_extmarks(bufnr)
      local overlay_count = 0
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text_pos == 'overlay' then
          overlay_count = overlay_count + 1
        end
      end
      assert.are.equal(0, overlay_count)
      delete_buffer(bufnr)
    end)

    it('applies DiffAdd background to + lines when background enabled', function()
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

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_diff_add = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].line_hl_group == 'DiffsAdd' then
          has_diff_add = true
          break
        end
      end
      assert.is_true(has_diff_add)
      delete_buffer(bufnr)
    end)

    it('applies DiffDelete background to - lines when background enabled', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,1 @@',
        ' local x = 1',
        '-local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '-local y = 2' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_diff_delete = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].line_hl_group == 'DiffsDelete' then
          has_diff_delete = true
          break
        end
      end
      assert.is_true(has_diff_delete)
      delete_buffer(bufnr)
    end)

    it('does not apply background when background disabled', function()
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

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = false } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_line_hl = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].line_hl_group then
          has_line_hl = true
          break
        end
      end
      assert.is_false(has_line_hl)
      delete_buffer(bufnr)
    end)

    it('applies number_hl_group when gutter enabled', function()
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

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true, gutter = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_number_hl = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].number_hl_group then
          has_number_hl = true
          break
        end
      end
      assert.is_true(has_number_hl)
      delete_buffer(bufnr)
    end)

    it('does not apply number_hl_group when gutter disabled', function()
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

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true, gutter = false } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_number_hl = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].number_hl_group then
          has_number_hl = true
          break
        end
      end
      assert.is_false(has_number_hl)
      delete_buffer(bufnr)
    end)

    it('skips treesitter highlights when treesitter disabled', function()
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

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { treesitter = { enabled = false }, background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_ts_highlight = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group:match('^@') then
          has_ts_highlight = true
          break
        end
      end
      assert.is_false(has_ts_highlight)
      delete_buffer(bufnr)
    end)

    it('still applies background when treesitter disabled', function()
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

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { treesitter = { enabled = false }, background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_diff_add = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].line_hl_group == 'DiffsAdd' then
          has_diff_add = true
          break
        end
      end
      assert.is_true(has_diff_add)
      delete_buffer(bufnr)
    end)

    it('applies vim syntax extmarks when vim.enabled and no TS parser', function()
      local orig_synID = vim.fn.synID
      local orig_synIDtrans = vim.fn.synIDtrans
      local orig_synIDattr = vim.fn.synIDattr
      vim.fn.synID = function(_line, _col, _trans)
        return 1
      end
      vim.fn.synIDtrans = function(id)
        return id
      end
      vim.fn.synIDattr = function(_id, _what)
        return 'Identifier'
      end

      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        ft = 'abap',
        lang = nil,
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { vim = { enabled = true } } })
      )

      vim.fn.synID = orig_synID
      vim.fn.synIDtrans = orig_synIDtrans
      vim.fn.synIDattr = orig_synIDattr

      local extmarks = get_extmarks(bufnr)
      local has_syntax_hl = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group ~= 'Normal' then
          has_syntax_hl = true
          break
        end
      end
      assert.is_true(has_syntax_hl)
      delete_buffer(bufnr)
    end)

    it('skips vim fallback when vim.enabled is false', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        ft = 'abap',
        lang = nil,
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { vim = { enabled = false } } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_syntax_hl = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group ~= 'Normal' then
          has_syntax_hl = true
          break
        end
      end
      assert.is_false(has_syntax_hl)
      delete_buffer(bufnr)
    end)

    it('respects vim.max_lines', function()
      local lines = { '@@ -1,100 +1,101 @@' }
      local hunk_lines = {}
      for i = 1, 250 do
        table.insert(lines, ' line ' .. i)
        table.insert(hunk_lines, ' line ' .. i)
      end

      local bufnr = create_buffer(lines)
      local hunk = {
        filename = 'test.lua',
        ft = 'abap',
        lang = nil,
        start_line = 1,
        lines = hunk_lines,
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { vim = { enabled = true, max_lines = 200 } } })
      )

      local extmarks = get_extmarks(bufnr)
      assert.are.equal(0, #extmarks)
      delete_buffer(bufnr)
    end)

    it('applies background for vim fallback hunks', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        ft = 'abap',
        lang = nil,
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { vim = { enabled = true }, background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_diff_add = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].line_hl_group == 'DiffsAdd' then
          has_diff_add = true
          break
        end
      end
      assert.is_true(has_diff_add)
      delete_buffer(bufnr)
    end)

    it('applies Normal blanking for vim fallback hunks', function()
      local orig_synID = vim.fn.synID
      local orig_synIDtrans = vim.fn.synIDtrans
      local orig_synIDattr = vim.fn.synIDattr
      vim.fn.synID = function(_line, _col, _trans)
        return 1
      end
      vim.fn.synIDtrans = function(id)
        return id
      end
      vim.fn.synIDattr = function(_id, _what)
        return 'Identifier'
      end

      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        ft = 'abap',
        lang = nil,
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { vim = { enabled = true } } })
      )

      vim.fn.synID = orig_synID
      vim.fn.synIDtrans = orig_synIDtrans
      vim.fn.synIDattr = orig_synIDattr

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
  end)

  describe('coalesce_syntax_spans', function()
    it('coalesces adjacent chars with same hl group', function()
      local function query_fn(_line, _col)
        return 1, 'Keyword'
      end
      local spans = highlight.coalesce_syntax_spans(query_fn, { 'hello' })
      assert.are.equal(1, #spans)
      assert.are.equal(1, spans[1].col_start)
      assert.are.equal(6, spans[1].col_end)
      assert.are.equal('Keyword', spans[1].hl_name)
    end)

    it('splits spans at hl group boundaries', function()
      local function query_fn(_line, col)
        if col <= 3 then
          return 1, 'Keyword'
        end
        return 2, 'String'
      end
      local spans = highlight.coalesce_syntax_spans(query_fn, { 'abcdef' })
      assert.are.equal(2, #spans)
      assert.are.equal('Keyword', spans[1].hl_name)
      assert.are.equal(1, spans[1].col_start)
      assert.are.equal(4, spans[1].col_end)
      assert.are.equal('String', spans[2].hl_name)
      assert.are.equal(4, spans[2].col_start)
      assert.are.equal(7, spans[2].col_end)
    end)

    it('skips syn_id 0 gaps', function()
      local function query_fn(_line, col)
        if col == 2 or col == 3 then
          return 0, ''
        end
        return 1, 'Identifier'
      end
      local spans = highlight.coalesce_syntax_spans(query_fn, { 'abcd' })
      assert.are.equal(2, #spans)
      assert.are.equal(1, spans[1].col_start)
      assert.are.equal(2, spans[1].col_end)
      assert.are.equal(4, spans[2].col_start)
      assert.are.equal(5, spans[2].col_end)
    end)

    it('skips empty hl_name spans', function()
      local function query_fn(_line, _col)
        return 1, ''
      end
      local spans = highlight.coalesce_syntax_spans(query_fn, { 'abc' })
      assert.are.equal(0, #spans)
    end)
  end)
end)
