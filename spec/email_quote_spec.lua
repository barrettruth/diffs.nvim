require('spec.helpers')
local highlight = require('diffs.highlight')
local parser = require('diffs.parser')

describe('email-quoted diffs', function()
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

  describe('parser', function()
    it('parses a fully email-quoted unified diff', function()
      local bufnr = create_buffer({
        '> diff --git a/foo.py b/foo.py',
        '> index abc1234..def5678 100644',
        '> --- a/foo.py',
        '> +++ b/foo.py',
        '> @@ -0,0 +1,3 @@',
        '> +from typing import Annotated, final',
        '> +',
        '> +class Foo:',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('foo.py', hunks[1].filename)
      assert.are.equal(3, #hunks[1].lines)
      assert.are.equal('+from typing import Annotated, final', hunks[1].lines[1])
      assert.are.equal(2, hunks[1].quote_width)
      delete_buffer(bufnr)
    end)

    it('parses a quoted diff embedded in an email reply', function()
      local bufnr = create_buffer({
        'Looks good, one nit:',
        '',
        '> diff --git a/foo.py b/foo.py',
        '> @@ -0,0 +1,3 @@',
        '> +from typing import Annotated, final',
        '> +',
        '> +class Foo:',
        '',
        'Maybe rename Foo to Bar?',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('foo.py', hunks[1].filename)
      assert.are.equal(3, #hunks[1].lines)
      assert.are.equal(2, hunks[1].quote_width)
      delete_buffer(bufnr)
    end)

    it('sets quote_width = 0 on normal (unquoted) diffs', function()
      local bufnr = create_buffer({
        'diff --git a/bar.lua b/bar.lua',
        '@@ -1,2 +1,2 @@',
        '-old_line',
        '+new_line',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(0, hunks[1].quote_width)
      delete_buffer(bufnr)
    end)

    it('treats bare > lines as empty quoted lines', function()
      local bufnr = create_buffer({
        '> diff --git a/foo.py b/foo.py',
        '> @@ -1,3 +1,3 @@',
        '> -old',
        '>',
        '> +new',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(3, #hunks[1].lines)
      assert.are.equal('-old', hunks[1].lines[1])
      assert.are.equal(' ', hunks[1].lines[2])
      assert.are.equal('+new', hunks[1].lines[3])
      delete_buffer(bufnr)
    end)

    it('handles deeply nested quotes', function()
      local bufnr = create_buffer({
        '>> diff --git a/foo.py b/foo.py',
        '>> @@ -0,0 +1,2 @@',
        '>> +line1',
        '>> +line2',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(3, hunks[1].quote_width)
      assert.are.equal('+line1', hunks[1].lines[1])
      delete_buffer(bufnr)
    end)

    it('adjusts header_context_col for quote width', function()
      local bufnr = create_buffer({
        '> diff --git a/foo.py b/foo.py',
        '> @@ -1,2 +1,2 @@ def hello():',
        '> -old',
        '> +new',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('def hello():', hunks[1].header_context)
      assert.are.equal(#'@@ -1,2 +1,2 @@ ' + 2, hunks[1].header_context_col)
      delete_buffer(bufnr)
    end)

    it('does not false-positive on prose containing > diff', function()
      local bufnr = create_buffer({
        '> diff between approaches is small',
        '> I think we should go with option A',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(0, #hunks)
      delete_buffer(bufnr)
    end)

    it('stores header lines stripped of quote prefix', function()
      local bufnr = create_buffer({
        '> diff --git a/foo.lua b/foo.lua',
        '> index abc1234..def5678 100644',
        '> --- a/foo.lua',
        '> +++ b/foo.lua',
        '> @@ -1,1 +1,1 @@',
        '> -old',
        '> +new',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.is_not_nil(hunks[1].header_lines)
      for _, hline in ipairs(hunks[1].header_lines) do
        assert.is_nil(hline:match('^> '))
      end
      delete_buffer(bufnr)
    end)
  end)

  describe('highlight', function()
    local ns

    before_each(function()
      ns = vim.api.nvim_create_namespace('diffs_email_test')
      vim.api.nvim_set_hl(0, 'DiffsClear', { fg = 0xc0c0c0, bg = 0x1e1e1e })
      vim.api.nvim_set_hl(0, 'DiffsAdd', { bg = 0x1a3a1a })
      vim.api.nvim_set_hl(0, 'DiffsDelete', { bg = 0x3a1a1a })
      vim.api.nvim_set_hl(0, 'DiffsConflictMarker', { fg = 0x808080, bold = true })
    end)

    local function get_extmarks(bufnr)
      return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    end

    local function default_opts(overrides)
      local opts = {
        hide_prefix = false,
        highlights = {
          background = true,
          gutter = false,
          context = { enabled = false, lines = 0 },
          treesitter = {
            enabled = true,
            max_lines = 500,
          },
          vim = {
            enabled = false,
            max_lines = 200,
          },
          intra = {
            enabled = false,
            algorithm = 'default',
            max_lines = 500,
          },
          priorities = {
            clear = 198,
            syntax = 199,
            line_bg = 200,
            char_bg = 201,
          },
        },
      }
      if overrides then
        if overrides.highlights then
          opts.highlights = vim.tbl_deep_extend('force', opts.highlights, overrides.highlights)
        end
        for k, v in pairs(overrides) do
          if k ~= 'highlights' then
            opts[k] = v
          end
        end
      end
      return opts
    end

    it('applies DiffsClear on email-quoted header lines covering full buffer width', function()
      local buf_lines = {
        '> diff --git a/foo.lua b/foo.lua',
        '> index abc1234..def5678 100644',
        '> --- a/foo.lua',
        '> +++ b/foo.lua',
        '> @@ -1,1 +1,1 @@',
        '> -old',
        '> +new',
      }
      local bufnr = create_buffer(buf_lines)

      local hunk = {
        filename = 'foo.lua',
        lang = 'lua',
        ft = 'lua',
        start_line = 5,
        lines = { '-old', '+new' },
        prefix_width = 1,
        quote_width = 2,
        header_start_line = 1,
        header_lines = {
          'diff --git a/foo.lua b/foo.lua',
          'index abc1234..def5678 100644',
          '--- a/foo.lua',
          '+++ b/foo.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local header_clears = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsClear' and mark[2] < 4 then
          table.insert(header_clears, { row = mark[2], col = mark[3], end_col = d.end_col })
        end
      end
      assert.is_true(#header_clears > 0)
      for _, c in ipairs(header_clears) do
        assert.are.equal(0, c.col)
        local buf_line_len = #buf_lines[c.row + 1]
        assert.are.equal(buf_line_len, c.end_col)
      end

      delete_buffer(bufnr)
    end)

    it('applies body prefix DiffsClear covering [0, pw+qw)', function()
      local bufnr = create_buffer({
        '> @@ -1,1 +1,1 @@',
        '> -old',
        '> +new',
      })

      local hunk = {
        filename = 'foo.lua',
        lang = 'lua',
        ft = 'lua',
        start_line = 1,
        lines = { '-old', '+new' },
        prefix_width = 1,
        quote_width = 2,
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local prefix_clears = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsClear' and d.end_col == 3 and mark[3] == 0 then
          table.insert(prefix_clears, { row = mark[2] })
        end
      end
      assert.are.equal(2, #prefix_clears)

      delete_buffer(bufnr)
    end)

    it('clamps body prefix DiffsClear on bare > lines (1-byte buffer line)', function()
      local bufnr = create_buffer({
        '> @@ -1,3 +1,3 @@',
        '> -old',
        '>',
        '> +new',
      })

      local hunk = {
        filename = 'foo.lua',
        ft = 'lua',
        lang = 'lua',
        start_line = 1,
        lines = { '-old', ' ', '+new' },
        prefix_width = 1,
        quote_width = 2,
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local bare_line_row = 2
      local bare_clears = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsClear' and mark[2] == bare_line_row and mark[3] == 0 then
          table.insert(bare_clears, { end_col = d.end_col })
        end
      end
      assert.are.equal(1, #bare_clears)
      assert.are.equal(1, bare_clears[1].end_col)

      delete_buffer(bufnr)
    end)

    it('applies per-char @diff.plus/@diff.minus at ci + qw', function()
      local bufnr = create_buffer({
        '> @@ -1,1 +1,1 @@',
        '> -old',
        '> +new',
      })

      local hunk = {
        filename = 'foo.lua',
        lang = 'lua',
        ft = 'lua',
        start_line = 1,
        lines = { '-old', '+new' },
        prefix_width = 1,
        quote_width = 2,
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local diff_marks = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == '@diff.plus' or d.hl_group == '@diff.minus') then
          table.insert(
            diff_marks,
            { row = mark[2], col = mark[3], end_col = d.end_col, hl = d.hl_group }
          )
        end
      end
      assert.is_true(#diff_marks >= 2)
      for _, dm in ipairs(diff_marks) do
        assert.are.equal(2, dm.col)
        assert.are.equal(3, dm.end_col)
      end

      delete_buffer(bufnr)
    end)

    it('offsets treesitter extmarks by pw + qw', function()
      local bufnr = create_buffer({
        '> @@ -1,1 +1,2 @@',
        '>  local x = 1',
        '> +local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        ft = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
        prefix_width = 1,
        quote_width = 2,
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local ts_marks = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group and d.hl_group:match('^@.*%.lua$') then
          table.insert(ts_marks, { row = mark[2], col = mark[3] })
        end
      end
      assert.is_true(#ts_marks > 0)
      for _, tm in ipairs(ts_marks) do
        assert.is_true(tm.col >= 3)
      end

      delete_buffer(bufnr)
    end)

    it('offsets intra-line char span extmarks by qw', function()
      local bufnr = create_buffer({
        '> @@ -1,1 +1,1 @@',
        '> -hello world',
        '> +hello earth',
      })

      local hunk = {
        filename = 'test.txt',
        ft = nil,
        lang = nil,
        start_line = 1,
        lines = { '-hello world', '+hello earth' },
        prefix_width = 1,
        quote_width = 2,
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({
          highlights = { intra = { enabled = true, algorithm = 'default', max_lines = 500 } },
        })
      )

      local extmarks = get_extmarks(bufnr)
      local char_marks = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == 'DiffsAddText' or d.hl_group == 'DiffsDeleteText') then
          table.insert(char_marks, { row = mark[2], col = mark[3], end_col = d.end_col })
        end
      end
      if #char_marks > 0 then
        for _, cm in ipairs(char_marks) do
          assert.is_true(cm.col >= 2)
        end
      end

      delete_buffer(bufnr)
    end)

    it('does not produce duplicate extmarks with syntax_only + qw', function()
      local bufnr = create_buffer({
        '> @@ -1,1 +1,2 @@',
        '>  local x = 1',
        '> +local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        ft = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2' },
        prefix_width = 1,
        quote_width = 2,
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())
      highlight.highlight_hunk(bufnr, ns, hunk, default_opts({ syntax_only = true }))

      local extmarks = get_extmarks(bufnr)
      local line_bg_count = 0
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.line_hl_group == 'DiffsAdd' then
          line_bg_count = line_bg_count + 1
        end
      end
      assert.are.equal(1, line_bg_count)

      delete_buffer(bufnr)
    end)
  end)
end)
