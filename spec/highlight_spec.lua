require('spec.helpers')
local highlight = require('diffs.highlight')

describe('highlight', function()
  describe('highlight_hunk', function()
    local ns

    before_each(function()
      ns = vim.api.nvim_create_namespace('diffs_test')
      local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
      local diff_add = vim.api.nvim_get_hl(0, { name = 'DiffAdd' })
      local diff_delete = vim.api.nvim_get_hl(0, { name = 'DiffDelete' })
      vim.api.nvim_set_hl(0, 'DiffsClear', { fg = normal.fg or 0xc0c0c0 })
      vim.api.nvim_set_hl(0, 'DiffsAdd', { bg = diff_add.bg })
      vim.api.nvim_set_hl(0, 'DiffsDelete', { bg = diff_delete.bg })
      vim.api.nvim_set_hl(0, 'DiffsConflictMarker', { fg = 0x808080, bold = true })
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
        if overrides.hide_prefix ~= nil then
          opts.hide_prefix = overrides.hide_prefix
        end
      end
      return opts
    end

    it('applies DiffsClear extmarks to clear diff colors', function()
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
      local has_clear = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsClear' then
          has_clear = true
          break
        end
      end
      assert.is_true(has_clear)
      delete_buffer(bufnr)
    end)

    it('produces treesitter captures on all lines with split parsing', function()
      local bufnr = create_buffer({
        '@@ -1,3 +1,3 @@',
        ' local x = 1',
        '-local y = 2',
        '+local y = 3',
        ' return x',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '-local y = 2', '+local y = 3', ' return x' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local lines_with_ts = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group:match('^@.*%.lua$') then
          lines_with_ts[mark[2]] = true
        end
      end
      assert.is_true(lines_with_ts[1] ~= nil)
      assert.is_true(lines_with_ts[2] ~= nil)
      assert.is_true(lines_with_ts[3] ~= nil)
      assert.is_true(lines_with_ts[4] ~= nil)
      delete_buffer(bufnr)
    end)

    it('skips hunks larger than max_lines', function()
      local lines = { '@@ -1,100 +1,101 @@' }
      local hunk_lines = {}
      for i = 1, 600 do
        table.insert(lines, '+line ' .. i)
        table.insert(hunk_lines, '+line ' .. i)
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

    it('highlights function keyword in header context', function()
      local bufnr = create_buffer({
        '@@ -5,3 +5,4 @@ function M.setup()',
        ' local x = 1',
        '+local y = 2',
        ' return x',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        header_context = 'function M.setup()',
        header_context_col = 18,
        lines = { ' local x = 1', '+local y = 2', ' return x' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local has_keyword_function = false
      for _, mark in ipairs(extmarks) do
        if mark[2] == 0 and mark[4] and mark[4].hl_group then
          local hl = mark[4].hl_group
          if hl == '@keyword.function.lua' or hl == '@keyword.lua' then
            has_keyword_function = true
            break
          end
        end
      end
      assert.is_true(has_keyword_function)
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
        if mark[4] and mark[4].hl_group == 'DiffsAdd' then
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
        if mark[4] and mark[4].hl_group == 'DiffsDelete' then
          has_diff_delete = true
          break
        end
      end
      assert.is_true(has_diff_delete)
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

    it('line bg uses hl_group with hl_eol not line_hl_group', function()
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
      local found = false
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsAdd' then
          assert.is_true(d.hl_eol)
          assert.is_nil(d.line_hl_group)
          found = true
        end
      end
      assert.is_true(found)
      delete_buffer(bufnr)
    end)

    it('line bg extmark survives adjacent clear_namespace starting at next row', function()
      local bufnr = create_buffer({
        'diff --git a/foo.py b/foo.py',
        '@@ -1,2 +1,2 @@',
        '-old',
        '+new',
      })

      local hunk = {
        filename = 'foo.py',
        header_start_line = 1,
        start_line = 2,
        lines = { '-old', '+new' },
        prefix_width = 1,
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true, treesitter = { enabled = false } } })
      )

      local last_body_row = hunk.start_line + #hunk.lines - 1
      vim.api.nvim_buf_clear_namespace(bufnr, ns, last_body_row + 1, last_body_row + 10)

      local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        ns,
        { last_body_row, 0 },
        { last_body_row, -1 },
        { details = true }
      )
      local has_line_bg = false
      for _, mark in ipairs(marks) do
        if mark[4] and mark[4].hl_group == 'DiffsAdd' then
          has_line_bg = true
        end
      end
      assert.is_true(has_line_bg)
      delete_buffer(bufnr)
    end)

    it('clear range covers last body line of hunk with header', function()
      local bufnr = create_buffer({
        'diff --git a/foo.py b/foo.py',
        'index abc..def 100644',
        '--- a/foo.py',
        '+++ b/foo.py',
        '@@ -1,3 +1,3 @@',
        ' ctx',
        '-old',
        '+new',
      })

      local hunk = {
        filename = 'foo.py',
        header_start_line = 1,
        start_line = 5,
        lines = { ' ctx', '-old', '+new' },
        prefix_width = 1,
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true, treesitter = { enabled = false } } })
      )

      local last_body_row = hunk.start_line + #hunk.lines - 1
      local clear_start = hunk.header_start_line - 1
      local clear_end = hunk.start_line + #hunk.lines
      vim.api.nvim_buf_clear_namespace(bufnr, ns, clear_start, clear_end)

      local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        ns,
        { last_body_row, 0 },
        { last_body_row, -1 },
        { details = false }
      )
      assert.are.equal(0, #marks)
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
        if mark[4] and mark[4].hl_group == 'DiffsAdd' then
          has_diff_add = true
          break
        end
      end
      assert.is_true(has_diff_add)
      delete_buffer(bufnr)
    end)

    it('applies DiffsAddNr prefix extmark on + line for pw=1', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,2 @@',
        '-old',
        '+new',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '-old', '+new' },
        prefix_width = 1,
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true, treesitter = { enabled = false } } })
      )

      local extmarks = get_extmarks(bufnr)
      local add_prefix = false
      local del_prefix = false
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.end_col == 1 and mark[3] == 0 then
          if d.hl_group == 'DiffsAddNr' and mark[2] == 2 then
            add_prefix = true
          end
          if d.hl_group == 'DiffsDeleteNr' and mark[2] == 1 then
            del_prefix = true
          end
        end
      end
      assert.is_true(add_prefix, 'DiffsAddNr on + prefix')
      assert.is_true(del_prefix, 'DiffsDeleteNr on - prefix')
      delete_buffer(bufnr)
    end)

    it('does not apply prefix extmark on context line', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,2 @@',
        ' ctx',
        '+new',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' ctx', '+new' },
        prefix_width = 1,
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true, treesitter = { enabled = false } } })
      )

      local extmarks = get_extmarks(bufnr)
      local ctx_prefix = false
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and mark[2] == 1 and mark[3] == 0 and d.end_col == 1 then
          if d.hl_group == 'DiffsAddNr' or d.hl_group == 'DiffsDeleteNr' then
            ctx_prefix = true
          end
        end
      end
      assert.is_false(ctx_prefix, 'no prefix extmark on context line')
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
        if mark[4] and mark[4].hl_group and mark[4].hl_group ~= 'DiffsClear' then
          has_syntax_hl = true
          break
        end
      end
      assert.is_true(has_syntax_hl)
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
        if mark[4] and mark[4].hl_group == 'DiffsAdd' then
          has_diff_add = true
          break
        end
      end
      assert.is_true(has_diff_add)
      delete_buffer(bufnr)
    end)

    it('applies DiffsClear blanking for vim fallback hunks', function()
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
      local has_clear = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsClear' then
          has_clear = true
          break
        end
      end
      assert.is_true(has_clear)
      delete_buffer(bufnr)
    end)

    it('uses hl_group with hl_eol for line backgrounds', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,1 @@',
        '-local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '-local x = 1', '+local y = 2' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local found = false
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') then
          found = true
        end
      end
      assert.is_true(found)
      delete_buffer(bufnr)
    end)

    it('number_hl_group does not bleed to adjacent lines', function()
      local bufnr = create_buffer({
        '@@ -1,3 +1,3 @@',
        ' local a = 0',
        '-local x = 1',
        '+local y = 2',
        ' local b = 3',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local a = 0', '-local x = 1', '+local y = 2', ' local b = 3' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true, gutter = true } })
      )

      local extmarks = get_extmarks(bufnr)
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.number_hl_group then
          local start_row = mark[2]
          local end_row = d.end_row or start_row
          assert.are.equal(start_row, end_row)
        end
      end
      delete_buffer(bufnr)
    end)

    it('creates char-level extmarks for changed characters', function()
      vim.api.nvim_set_hl(0, 'DiffsAddText', { bg = 0x00FF00 })
      vim.api.nvim_set_hl(0, 'DiffsDeleteText', { bg = 0xFF0000 })

      local bufnr = create_buffer({
        '@@ -1,2 +1,2 @@',
        '-local x = 1',
        '+local x = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '-local x = 1', '+local x = 2' },
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
      local add_text_marks = {}
      local del_text_marks = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsAddText' then
          table.insert(add_text_marks, mark)
        end
        if d and d.hl_group == 'DiffsDeleteText' then
          table.insert(del_text_marks, mark)
        end
      end
      assert.is_true(#add_text_marks > 0)
      assert.is_true(#del_text_marks > 0)
      delete_buffer(bufnr)
    end)

    it('does not create char-level extmarks for pure additions', function()
      vim.api.nvim_set_hl(0, 'DiffsAddText', { bg = 0x00FF00 })

      local bufnr = create_buffer({
        '@@ -1,0 +1,2 @@',
        '+local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '+local x = 1', '+local y = 2' },
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
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        assert.is_not_equal('DiffsAddText', d and d.hl_group)
        assert.is_not_equal('DiffsDeleteText', d and d.hl_group)
      end
      delete_buffer(bufnr)
    end)

    it('enforces priority order: DiffsClear < syntax < line bg < char bg', function()
      vim.api.nvim_set_hl(0, 'DiffsAddText', { bg = 0x00FF00 })
      vim.api.nvim_set_hl(0, 'DiffsDeleteText', { bg = 0xFF0000 })

      local bufnr = create_buffer({
        '@@ -1,2 +1,2 @@',
        '-local x = 1',
        '+local x = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '-local x = 1', '+local x = 2' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({
          highlights = {
            background = true,
            intra = { enabled = true, algorithm = 'default', max_lines = 500 },
          },
        })
      )

      local extmarks = get_extmarks(bufnr)
      local priorities = { clear = {}, line_bg = {}, syntax = {}, char_bg = {} }
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d then
          if d.hl_group == 'DiffsClear' then
            table.insert(priorities.clear, d.priority)
          elseif d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete' then
            table.insert(priorities.line_bg, d.priority)
          elseif d.hl_group == 'DiffsAddText' or d.hl_group == 'DiffsDeleteText' then
            table.insert(priorities.char_bg, d.priority)
          elseif d.hl_group and d.hl_group:match('^@.*%.lua$') then
            table.insert(priorities.syntax, d.priority)
          end
        end
      end

      assert.is_true(#priorities.clear > 0)
      assert.is_true(#priorities.line_bg > 0)
      assert.is_true(#priorities.syntax > 0)
      assert.is_true(#priorities.char_bg > 0)

      local max_clear = math.max(unpack(priorities.clear))
      local min_line_bg = math.min(unpack(priorities.line_bg))
      local min_syntax = math.min(unpack(priorities.syntax))
      local min_char_bg = math.min(unpack(priorities.char_bg))

      assert.is_true(max_clear < min_syntax)
      assert.is_true(min_syntax < min_line_bg)
      assert.is_true(min_line_bg < min_char_bg)
      delete_buffer(bufnr)
    end)

    it('includes captures from both base and injected languages', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+vim.cmd([[ echo 1 ]])',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+vim.cmd([[ echo 1 ]])' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local has_lua = false
      local has_vim = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group then
          if mark[4].hl_group:match('^@.*%.lua$') then
            has_lua = true
          end
          if mark[4].hl_group:match('^@.*%.vim$') then
            has_vim = true
          end
        end
      end
      assert.is_true(has_lua)
      assert.is_true(has_vim)
      delete_buffer(bufnr)
    end)

    it('classifies all combined diff prefix types for background', function()
      local bufnr = create_buffer({
        '@@@ -1,5 -1,5 +1,9 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        ' +  return 1',
        '+ local greeting = "hi"',
        '++=======',
        '+   return 2',
        '++>>>>>>> feature',
        '  end',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        prefix_width = 2,
        lines = {
          '  local M = {}',
          '++<<<<<<< HEAD',
          ' +  return 1',
          '+ local greeting = "hi"',
          '++=======',
          '+   return 2',
          '++>>>>>>> feature',
          '  end',
        },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local line_bgs = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') then
          line_bgs[mark[2]] = d.hl_group
        end
      end
      assert.is_nil(line_bgs[1])
      assert.are.equal('DiffsAdd', line_bgs[2])
      assert.are.equal('DiffsAdd', line_bgs[3])
      assert.are.equal('DiffsAdd', line_bgs[4])
      assert.are.equal('DiffsAdd', line_bgs[5])
      assert.are.equal('DiffsAdd', line_bgs[6])
      assert.are.equal('DiffsAdd', line_bgs[7])
      assert.is_nil(line_bgs[8])
      delete_buffer(bufnr)
    end)

    it('conceals full 2-char prefix for all combined diff line types', function()
      local bufnr = create_buffer({
        '@@@ -1,3 -1,3 +1,5 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        ' +  return 1',
        '+ local x = 2',
        '  end',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        prefix_width = 2,
        lines = {
          '  local M = {}',
          '++<<<<<<< HEAD',
          ' +  return 1',
          '+ local x = 2',
          '  end',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts({ hide_prefix = true }))

      local extmarks = get_extmarks(bufnr)
      local overlays = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].virt_text_pos == 'overlay' then
          overlays[mark[2]] = mark[4].virt_text[1][1]
        end
      end
      assert.are.equal(5, vim.tbl_count(overlays))
      for _, text in pairs(overlays) do
        assert.are.equal('  ', text)
      end
      delete_buffer(bufnr)
    end)

    it('places treesitter captures at col_offset 2 for combined diffs', function()
      local bufnr = create_buffer({
        '@@@ -1,2 -1,2 +1,2 @@@',
        '  local x = 1',
        ' +local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        prefix_width = 2,
        lines = { '  local x = 1', ' +local y = 2' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local ts_marks = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group:match('^@.*%.lua$') then
          table.insert(ts_marks, mark)
        end
      end
      assert.is_true(#ts_marks > 0)
      for _, mark in ipairs(ts_marks) do
        assert.is_true(mark[3] >= 2)
      end
      delete_buffer(bufnr)
    end)

    it('applies DiffsClear starting at col 2 for combined diffs', function()
      local bufnr = create_buffer({
        '@@@ -1,1 -1,1 +1,2 @@@',
        '  local x = 1',
        ' +local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        prefix_width = 2,
        lines = { '  local x = 1', ' +local y = 2' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local content_clear_count = 0
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsClear' then
          assert.is_true(mark[3] == 0 or mark[3] == 2, 'DiffsClear at unexpected col ' .. mark[3])
          if mark[3] == 2 then
            content_clear_count = content_clear_count + 1
          end
        end
      end
      assert.are.equal(2, content_clear_count)
      delete_buffer(bufnr)
    end)

    it('skips intra-line diffing for combined diffs', function()
      vim.api.nvim_set_hl(0, 'DiffsAddText', { bg = 0x00FF00 })
      vim.api.nvim_set_hl(0, 'DiffsDeleteText', { bg = 0xFF0000 })

      local bufnr = create_buffer({
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local x = 1',
        ' +local y = 2',
        '+ local y = 3',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        prefix_width = 2,
        lines = { '  local x = 1', ' +local y = 2', '+ local y = 3' },
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
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        assert.is_not_equal('DiffsAddText', d and d.hl_group)
        assert.is_not_equal('DiffsDeleteText', d and d.hl_group)
      end
      delete_buffer(bufnr)
    end)

    it('applies DiffsConflictMarker text on markers with DiffsAdd bg', function()
      local bufnr = create_buffer({
        '@@@ -1,5 -1,5 +1,9 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        '+ local x = 1',
        '++||||||| base',
        '++=======',
        ' +local y = 2',
        '++>>>>>>> feature',
        '  return M',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        prefix_width = 2,
        lines = {
          '  local M = {}',
          '++<<<<<<< HEAD',
          '+ local x = 1',
          '++||||||| base',
          '++=======',
          ' +local y = 2',
          '++>>>>>>> feature',
          '  return M',
        },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true, gutter = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local line_bgs = {}
      local gutter_hls = {}
      local marker_text = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') then
          line_bgs[mark[2]] = d.hl_group
        end
        if d and d.number_hl_group then
          gutter_hls[mark[2]] = d.number_hl_group
        end
        if d and d.hl_group == 'DiffsConflictMarker' then
          marker_text[mark[2]] = true
        end
      end

      assert.is_nil(line_bgs[1])
      assert.are.equal('DiffsAdd', line_bgs[2])
      assert.are.equal('DiffsAdd', line_bgs[3])
      assert.are.equal('DiffsAdd', line_bgs[4])
      assert.are.equal('DiffsAdd', line_bgs[5])
      assert.are.equal('DiffsAdd', line_bgs[6])
      assert.are.equal('DiffsAdd', line_bgs[7])
      assert.is_nil(line_bgs[8])

      assert.is_nil(gutter_hls[1])
      assert.are.equal('DiffsAddNr', gutter_hls[2])
      assert.are.equal('DiffsAddNr', gutter_hls[3])
      assert.are.equal('DiffsAddNr', gutter_hls[4])
      assert.are.equal('DiffsAddNr', gutter_hls[5])
      assert.are.equal('DiffsAddNr', gutter_hls[6])
      assert.are.equal('DiffsAddNr', gutter_hls[7])
      assert.is_nil(gutter_hls[8])

      assert.is_true(marker_text[2] ~= nil)
      assert.is_nil(marker_text[3])
      assert.is_true(marker_text[4] ~= nil)
      assert.is_true(marker_text[5] ~= nil)
      assert.is_nil(marker_text[6])
      assert.is_true(marker_text[7] ~= nil)
      delete_buffer(bufnr)
    end)

    it('does not apply DiffsConflictMarker in unified diffs', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,4 @@',
        ' local M = {}',
        '+<<<<<<< HEAD',
        '+local x = 1',
        '+=======',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local M = {}', '+<<<<<<< HEAD', '+local x = 1', '+=======' },
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        assert.is_not_equal('DiffsConflictMarker', d and d.hl_group)
      end
      delete_buffer(bufnr)
    end)

    it('filters @spell and @nospell captures from injections', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+vim.cmd([[ echo 1 ]])',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+vim.cmd([[ echo 1 ]])' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group then
          assert.is_falsy(mark[4].hl_group:match('@spell'))
          assert.is_falsy(mark[4].hl_group:match('@nospell'))
        end
      end
      delete_buffer(bufnr)
    end)

    it('two-pass rendering produces no duplicate extmarks', function()
      vim.api.nvim_set_hl(0, 'DiffsAddText', { bg = 0x00FF00 })
      vim.api.nvim_set_hl(0, 'DiffsDeleteText', { bg = 0xFF0000 })
      vim.api.nvim_set_hl(0, 'DiffsAddNr', { fg = 0x80c080, bg = 0x2e4a3a })
      vim.api.nvim_set_hl(0, 'DiffsDeleteNr', { fg = 0xc08080, bg = 0x4a2e3a })

      local bufnr = create_buffer({
        '@@ -1,2 +1,2 @@',
        '-local x = 1',
        '+local x = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '-local x = 1', '+local x = 2' },
      }

      local fast = default_opts({
        highlights = {
          treesitter = { enabled = false },
          background = true,
          gutter = true,
          intra = { enabled = true, algorithm = 'default', max_lines = 500 },
        },
      })

      local syntax = default_opts({
        highlights = {
          treesitter = { enabled = true },
          background = true,
          gutter = true,
          intra = { enabled = true, algorithm = 'default', max_lines = 500 },
        },
      })
      syntax.syntax_only = true

      highlight.highlight_hunk(bufnr, ns, hunk, fast)
      highlight.highlight_hunk(bufnr, ns, hunk, syntax)

      local extmarks = get_extmarks(bufnr)
      for row = 1, 2 do
        local line_hl_count = 0
        local number_hl_count = 0
        local intra_count = 0
        for _, mark in ipairs(extmarks) do
          if mark[2] == row then
            local d = mark[4]
            if d.hl_group and d.hl_eol then
              line_hl_count = line_hl_count + 1
            end
            if d.number_hl_group then
              number_hl_count = number_hl_count + 1
            end
            if d.hl_group == 'DiffsAddText' or d.hl_group == 'DiffsDeleteText' then
              intra_count = intra_count + 1
            end
          end
        end
        assert.are.equal(1, line_hl_count, 'row ' .. row .. ' has duplicate line bg')
        assert.are.equal(1, number_hl_count, 'row ' .. row .. ' has duplicate number_hl_group')
        assert.is_true(intra_count <= 1, 'row ' .. row .. ' has duplicate intra extmarks')
      end
      delete_buffer(bufnr)
    end)

    it('syntax_only pass adds treesitter without duplicating backgrounds', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        '+local y = 2',
        ' return x',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local x = 1', '+local y = 2', ' return x' },
      }

      local fast = default_opts({
        highlights = {
          treesitter = { enabled = false },
          background = true,
        },
      })

      local syntax = default_opts({
        highlights = {
          treesitter = { enabled = true },
          background = true,
        },
      })
      syntax.syntax_only = true

      highlight.highlight_hunk(bufnr, ns, hunk, fast)
      highlight.highlight_hunk(bufnr, ns, hunk, syntax)

      local extmarks = get_extmarks(bufnr)
      local has_ts = false
      local line_bg_count = 0
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group and d.hl_group:match('^@.*%.lua$') then
          has_ts = true
        end
        if d and d.hl_group and d.hl_eol then
          line_bg_count = line_bg_count + 1
        end
      end
      assert.is_true(has_ts)
      assert.are.equal(1, line_bg_count)
      delete_buffer(bufnr)
    end)
  end)

  describe('diff header highlighting', function()
    local ns

    before_each(function()
      ns = vim.api.nvim_create_namespace('diffs_test_header')
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

    local function default_opts()
      return {
        hide_prefix = false,
        highlights = {
          background = false,
          gutter = false,
          context = { enabled = false, lines = 0 },
          treesitter = { enabled = true, max_lines = 500 },
          vim = { enabled = false, max_lines = 200 },
          priorities = { clear = 198, syntax = 199, line_bg = 200, char_bg = 201 },
        },
      }
    end

    it('applies treesitter extmarks to diff header lines', function()
      local bufnr = create_buffer({
        'diff --git a/parser.lua b/parser.lua',
        'index 3e8afa0..018159c 100644',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })

      local hunk = {
        filename = 'parser.lua',
        lang = 'lua',
        start_line = 5,
        lines = { ' local M = {}', '+local x = 1' },
        header_start_line = 1,
        header_lines = {
          'diff --git a/parser.lua b/parser.lua',
          'index 3e8afa0..018159c 100644',
          '--- a/parser.lua',
          '+++ b/parser.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local header_extmarks = {}
      for _, mark in ipairs(extmarks) do
        if mark[2] < 4 and mark[4] and mark[4].hl_group then
          table.insert(header_extmarks, mark)
        end
      end

      assert.is_true(#header_extmarks > 0)

      local has_function_hl = false
      local has_keyword_hl = false
      for _, mark in ipairs(header_extmarks) do
        local hl = mark[4].hl_group
        if hl == '@function' or hl == '@function.diff' then
          has_function_hl = true
        end
        if hl == '@keyword' or hl == '@keyword.diff' then
          has_keyword_hl = true
        end
      end
      assert.is_true(has_function_hl or has_keyword_hl)
      delete_buffer(bufnr)
    end)

    it('does not apply header highlights when header_lines missing', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })

      local hunk = {
        filename = 'parser.lua',
        lang = 'lua',
        start_line = 1,
        lines = { ' local M = {}', '+local x = 1' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local header_extmarks = 0
      for _, mark in ipairs(extmarks) do
        if mark[2] < 0 and mark[4] and mark[4].hl_group then
          header_extmarks = header_extmarks + 1
        end
      end
      assert.are.equal(0, header_extmarks)
      delete_buffer(bufnr)
    end)

    it('does not apply DiffsClear to header lines for non-quoted diffs', function()
      local bufnr = create_buffer({
        'diff --git a/parser.lua b/parser.lua',
        'index 3e8afa0..018159c 100644',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })

      local hunk = {
        filename = 'parser.lua',
        lang = 'lua',
        start_line = 5,
        lines = { ' local M = {}', '+local x = 1' },
        header_start_line = 1,
        header_lines = {
          'diff --git a/parser.lua b/parser.lua',
          'index 3e8afa0..018159c 100644',
          '--- a/parser.lua',
          '+++ b/parser.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsClear' and mark[3] == 0 and mark[2] < 4 then
          error('unexpected DiffsClear on header row ' .. mark[2] .. ' for non-quoted diff')
        end
      end
      delete_buffer(bufnr)
    end)

    it('preserves diff grammar treesitter on headers for non-quoted diffs', function()
      local bufnr = create_buffer({
        'diff --git a/parser.lua b/parser.lua',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })

      local hunk = {
        filename = 'parser.lua',
        lang = 'lua',
        start_line = 4,
        lines = { ' local M = {}', '+local x = 1' },
        header_start_line = 1,
        header_lines = {
          'diff --git a/parser.lua b/parser.lua',
          '--- a/parser.lua',
          '+++ b/parser.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local header_ts_count = 0
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if mark[2] < 3 and d and d.hl_group and d.hl_group:match('^@.*%.diff$') then
          header_ts_count = header_ts_count + 1
        end
      end
      assert.is_true(header_ts_count > 0, 'expected diff grammar treesitter on header lines')
      delete_buffer(bufnr)
    end)

    it('applies syntax extmarks to combined diff body lines', function()
      local bufnr = create_buffer({
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local M = {}',
        '+ local x = 1',
        ' -local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 1,
        lines = { '  local M = {}', '+ local x = 1', ' -local y = 2' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local syntax_on_body = 0
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if mark[2] >= 1 and d and d.hl_group and d.hl_group:match('^@.*%.lua$') then
          syntax_on_body = syntax_on_body + 1
        end
      end
      assert.is_true(syntax_on_body > 0, 'expected lua treesitter syntax on combined diff body')
      delete_buffer(bufnr)
    end)

    it('applies DiffsClear and per-char diff fg to combined diff body prefixes', function()
      local bufnr = create_buffer({
        '@@@',
        '  unchanged',
        '+ added',
        ' -removed',
        '++both',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 1,
        lines = { '  unchanged', '+ added', ' -removed', '++both' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local prefix_clears = {}
      local plus_marks = {}
      local minus_marks = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if mark[2] >= 1 and d then
          if d.hl_group == 'DiffsClear' and mark[3] == 0 and d.end_col == 2 then
            prefix_clears[mark[2]] = true
          end
          if d.hl_group == '@diff.plus' and d.priority == 199 then
            if not plus_marks[mark[2]] then
              plus_marks[mark[2]] = {}
            end
            table.insert(plus_marks[mark[2]], mark[3])
          end
          if d.hl_group == '@diff.minus' and d.priority == 199 then
            if not minus_marks[mark[2]] then
              minus_marks[mark[2]] = {}
            end
            table.insert(minus_marks[mark[2]], mark[3])
          end
        end
      end

      assert.is_true(prefix_clears[1] ~= nil, 'DiffsClear on context prefix')
      assert.is_true(prefix_clears[2] ~= nil, 'DiffsClear on add prefix')
      assert.is_true(prefix_clears[3] ~= nil, 'DiffsClear on del prefix')
      assert.is_true(prefix_clears[4] ~= nil, 'DiffsClear on both-add prefix')

      assert.is_true(plus_marks[2] ~= nil, '@diff.plus on + in "+ added"')
      assert.are.equal(0, plus_marks[2][1])

      assert.is_true(minus_marks[3] ~= nil, '@diff.minus on - in " -removed"')
      assert.are.equal(1, minus_marks[3][1])

      assert.is_true(plus_marks[4] ~= nil, '@diff.plus on ++ in "++both"')
      assert.are.equal(2, #plus_marks[4])

      assert.is_nil(plus_marks[1], 'no @diff.plus on context "  unchanged"')
      assert.is_nil(minus_marks[1], 'no @diff.minus on context "  unchanged"')
      delete_buffer(bufnr)
    end)

    it('applies DiffsClear to headers for combined diffs', function()
      local bufnr = create_buffer({
        'diff --combined lua/merge/target.lua',
        'index abc1234,def5678..a6b9012',
        '--- a/lua/merge/target.lua',
        '+++ b/lua/merge/target.lua',
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local M = {}',
        '+ local x = 1',
      })

      local hunk = {
        filename = 'lua/merge/target.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 5,
        lines = { '  local M = {}', '+ local x = 1' },
        header_start_line = 1,
        header_lines = {
          'diff --combined lua/merge/target.lua',
          'index abc1234,def5678..a6b9012',
          '--- a/lua/merge/target.lua',
          '+++ b/lua/merge/target.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local clear_lines = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsClear' and mark[3] == 0 and mark[2] < 4 then
          clear_lines[mark[2]] = true
        end
      end
      assert.is_true(clear_lines[0] ~= nil, 'DiffsClear on diff --combined line')
      assert.is_true(clear_lines[1] ~= nil, 'DiffsClear on index line')
      assert.is_true(clear_lines[2] ~= nil, 'DiffsClear on --- line')
      assert.is_true(clear_lines[3] ~= nil, 'DiffsClear on +++ line')
      delete_buffer(bufnr)
    end)

    it('applies @attribute.diff at syntax priority to @@@ line for combined diffs', function()
      local bufnr = create_buffer({
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local M = {}',
        '+ local x = 1',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 1,
        lines = { '  local M = {}', '+ local x = 1' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local has_attr = false
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if mark[2] == 0 and d and d.hl_group == '@attribute.diff' and (d.priority or 0) >= 199 then
          has_attr = true
        end
      end
      assert.is_true(has_attr, '@attribute.diff at p>=199 on @@@ line')
      delete_buffer(bufnr)
    end)

    it('applies DiffsClear to @@@ line for combined diffs', function()
      local bufnr = create_buffer({
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local M = {}',
        '+ local x = 1',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 1,
        lines = { '  local M = {}', '+ local x = 1' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local has_at_clear = false
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if mark[2] == 0 and d and d.hl_group == 'DiffsClear' and mark[3] == 0 then
          has_at_clear = true
        end
      end
      assert.is_true(has_at_clear, 'DiffsClear on @@@ line')
      delete_buffer(bufnr)
    end)

    it('applies header diff grammar at syntax priority for combined diffs', function()
      local bufnr = create_buffer({
        'diff --combined lua/merge/target.lua',
        'index abc1234,def5678..a6b9012',
        '--- a/lua/merge/target.lua',
        '+++ b/lua/merge/target.lua',
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local M = {}',
        '+ local x = 1',
      })

      local hunk = {
        filename = 'lua/merge/target.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 5,
        lines = { '  local M = {}', '+ local x = 1' },
        header_start_line = 1,
        header_lines = {
          'diff --combined lua/merge/target.lua',
          'index abc1234,def5678..a6b9012',
          '--- a/lua/merge/target.lua',
          '+++ b/lua/merge/target.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local high_prio_diff = {}
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if
          mark[2] < 4
          and d
          and d.hl_group
          and d.hl_group:match('^@.*%.diff$')
          and (d.priority or 0) >= 199
        then
          high_prio_diff[mark[2]] = true
        end
      end
      assert.is_true(high_prio_diff[2] ~= nil, 'diff grammar at p>=199 on --- line')
      assert.is_true(high_prio_diff[3] ~= nil, 'diff grammar at p>=199 on +++ line')
      delete_buffer(bufnr)
    end)

    it('@diff.minus wins over @punctuation.special on combined diff headers', function()
      local bufnr = create_buffer({
        'diff --combined lua/merge/target.lua',
        'index abc1234,def5678..a6b9012',
        '--- a/lua/merge/target.lua',
        '+++ b/lua/merge/target.lua',
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local M = {}',
        '+ local x = 1',
      })

      local hunk = {
        filename = 'lua/merge/target.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 5,
        lines = { '  local M = {}', '+ local x = 1' },
        header_start_line = 1,
        header_lines = {
          'diff --combined lua/merge/target.lua',
          'index abc1234,def5678..a6b9012',
          '--- a/lua/merge/target.lua',
          '+++ b/lua/merge/target.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local minus_prio, punct_prio_minus = 0, 0
      local plus_prio, punct_prio_plus = 0, 0
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group then
          if mark[2] == 2 then
            if d.hl_group == '@diff.minus.diff' then
              minus_prio = math.max(minus_prio, d.priority or 0)
            elseif d.hl_group == '@punctuation.special.diff' then
              punct_prio_minus = math.max(punct_prio_minus, d.priority or 0)
            end
          elseif mark[2] == 3 then
            if d.hl_group == '@diff.plus.diff' then
              plus_prio = math.max(plus_prio, d.priority or 0)
            elseif d.hl_group == '@punctuation.special.diff' then
              punct_prio_plus = math.max(punct_prio_plus, d.priority or 0)
            end
          end
        end
      end
      assert.is_true(
        minus_prio > punct_prio_minus,
        '@diff.minus.diff should beat @punctuation.special.diff on --- line'
      )
      assert.is_true(
        plus_prio > punct_prio_plus,
        '@diff.plus.diff should beat @punctuation.special.diff on +++ line'
      )
      delete_buffer(bufnr)
    end)

    it('applies @keyword.diff on index word for combined diffs', function()
      local bufnr = create_buffer({
        'diff --combined lua/merge/target.lua',
        'index abc1234,def5678..a6b9012',
        '--- a/lua/merge/target.lua',
        '+++ b/lua/merge/target.lua',
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local M = {}',
        '+ local x = 1',
      })

      local hunk = {
        filename = 'lua/merge/target.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 5,
        lines = { '  local M = {}', '+ local x = 1' },
        header_start_line = 1,
        header_lines = {
          'diff --combined lua/merge/target.lua',
          'index abc1234,def5678..a6b9012',
          '--- a/lua/merge/target.lua',
          '+++ b/lua/merge/target.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local has_keyword = false
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if
          mark[2] == 1
          and d
          and d.hl_group == '@keyword.diff'
          and mark[3] == 0
          and (d.end_col or 0) == 5
        then
          has_keyword = true
        end
      end
      assert.is_true(has_keyword, '@keyword.diff at row 1, cols 0-5')
      delete_buffer(bufnr)
    end)

    it('applies @constant.diff on result hash for combined diffs', function()
      local bufnr = create_buffer({
        'diff --combined lua/merge/target.lua',
        'index abc1234,def5678..a6b9012',
        '--- a/lua/merge/target.lua',
        '+++ b/lua/merge/target.lua',
        '@@@ -1,2 -1,2 +1,3 @@@',
        '  local M = {}',
        '+ local x = 1',
      })

      local hunk = {
        filename = 'lua/merge/target.lua',
        lang = 'lua',
        prefix_width = 2,
        start_line = 5,
        lines = { '  local M = {}', '+ local x = 1' },
        header_start_line = 1,
        header_lines = {
          'diff --combined lua/merge/target.lua',
          'index abc1234,def5678..a6b9012',
          '--- a/lua/merge/target.lua',
          '+++ b/lua/merge/target.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local has_result_hash = false
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if
          mark[2] == 1
          and mark[3] == 23
          and d
          and d.hl_group == '@constant.diff'
          and d.end_col == 30
          and (d.priority or 0) >= 199
        then
          has_result_hash = true
        end
      end
      assert.is_true(has_result_hash, '@constant.diff on result hash at cols 23-30')
      delete_buffer(bufnr)
    end)
  end)

  describe('extmark priority', function()
    local ns

    before_each(function()
      ns = vim.api.nvim_create_namespace('diffs_test_priority')
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

    local function default_opts()
      return {
        hide_prefix = false,
        highlights = {
          background = false,
          gutter = false,
          context = { enabled = false, lines = 0 },
          treesitter = { enabled = true, max_lines = 500 },
          vim = { enabled = false, max_lines = 200 },
          priorities = { clear = 198, syntax = 199, line_bg = 200, char_bg = 201 },
        },
      }
    end

    it('uses treesitter priority for diff language', function()
      local bufnr = create_buffer({
        'diff --git a/test.lua b/test.lua',
        '--- a/test.lua',
        '+++ b/test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 5,
        lines = { ' local x = 1', '+local y = 2' },
        header_start_line = 1,
        header_lines = {
          'diff --git a/test.lua b/test.lua',
          '--- a/test.lua',
          '+++ b/test.lua',
        },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      local diff_extmark_priorities = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group:match('^@.*%.diff$') then
          table.insert(diff_extmark_priorities, mark[4].priority)
        end
      end
      assert.is_true(#diff_extmark_priorities > 0)
      for _, priority in ipairs(diff_extmark_priorities) do
        assert.is_true(priority < 199)
      end
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
