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
        if mark[4] and (mark[4].hl_group == 'DiffsAdd' or mark[4].hl_group == 'DiffsDelete') then
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
        if mark[4] and mark[4].hl_group == 'DiffsAdd' then
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
        if mark[4] and mark[4].hl_group and mark[4].hl_group ~= 'DiffsClear' then
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
        if mark[4] and mark[4].hl_group and mark[4].hl_group ~= 'DiffsClear' then
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

    it('uses hl_group not line_hl_group for line backgrounds', function()
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
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') then
          assert.is_true(d.hl_eol == true)
          assert.is_nil(d.line_hl_group)
        end
      end
      delete_buffer(bufnr)
    end)

    it('hl_eol background extmarks are multiline so hl_eol takes effect', function()
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
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') then
          assert.is_true(d.end_row > mark[2])
        end
      end
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

    it('line bg priority > DiffsClear priority', function()
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
      local clear_priority = nil
      local line_bg_priority = nil
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and d.hl_group == 'DiffsClear' then
          clear_priority = d.priority
        end
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') then
          line_bg_priority = d.priority
        end
      end
      assert.is_not_nil(clear_priority)
      assert.is_not_nil(line_bg_priority)
      assert.is_true(line_bg_priority > clear_priority)
      delete_buffer(bufnr)
    end)

    it('char-level extmarks have higher priority than line bg', function()
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
      local line_bg_priority = nil
      local char_bg_priority = nil
      for _, mark in ipairs(extmarks) do
        local d = mark[4]
        if d and (d.hl_group == 'DiffsAdd' or d.hl_group == 'DiffsDelete') then
          line_bg_priority = d.priority
        end
        if d and (d.hl_group == 'DiffsAddText' or d.hl_group == 'DiffsDeleteText') then
          char_bg_priority = d.priority
        end
      end
      assert.is_not_nil(line_bg_priority)
      assert.is_not_nil(char_bg_priority)
      assert.is_true(char_bg_priority > line_bg_priority)
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

    it('does not create char-level extmarks when intra disabled', function()
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
          highlights = { intra = { enabled = false, algorithm = 'default', max_lines = 500 } },
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

    it('context padding produces no extmarks on padding lines', function()
      local repo_root = '/tmp/diffs-test-context'
      vim.fn.mkdir(repo_root, 'p')

      local f = io.open(repo_root .. '/test.lua', 'w')
      f:write('local M = {}\n')
      f:write('function M.hello()\n')
      f:write('  return "hi"\n')
      f:write('end\n')
      f:write('return M\n')
      f:close()

      local bufnr = create_buffer({
        '@@ -3,1 +3,2 @@',
        ' return "hi"',
        '+"bye"',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 1,
        lines = { '  return "hi"', '+"bye"' },
        file_old_start = 3,
        file_old_count = 1,
        file_new_start = 3,
        file_new_count = 2,
        repo_root = repo_root,
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { context = { enabled = true, lines = 25 } } })
      )

      local extmarks = get_extmarks(bufnr)
      for _, mark in ipairs(extmarks) do
        local row = mark[2]
        assert.is_true(row >= 1 and row <= 2)
      end

      delete_buffer(bufnr)
      os.remove(repo_root .. '/test.lua')
      vim.fn.delete(repo_root, 'rf')
    end)

    it('context disabled matches behavior without padding', function()
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
        file_new_start = 1,
        file_new_count = 2,
        repo_root = '/nonexistent',
      }

      highlight.highlight_hunk(
        bufnr,
        ns,
        hunk,
        default_opts({ highlights = { context = { enabled = false, lines = 0 } } })
      )

      local extmarks = get_extmarks(bufnr)
      assert.is_true(#extmarks > 0)
      delete_buffer(bufnr)
    end)

    it('gracefully handles missing file for context padding', function()
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
        file_new_start = 1,
        file_new_count = 2,
        repo_root = '/nonexistent/path',
      }

      assert.has_no.errors(function()
        highlight.highlight_hunk(
          bufnr,
          ns,
          hunk,
          default_opts({ highlights = { context = { enabled = true, lines = 25 } } })
        )
      end)

      local extmarks = get_extmarks(bufnr)
      assert.is_true(#extmarks > 0)
      delete_buffer(bufnr)
    end)

    it('highlights treesitter injections', function()
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
      local has_vim_capture = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group:match('^@.*%.vim$') then
          has_vim_capture = true
          break
        end
      end
      assert.is_true(has_vim_capture)
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

    it('does not apply header highlights when treesitter disabled', function()
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

      local opts = default_opts()
      opts.highlights.treesitter.enabled = false

      highlight.highlight_hunk(bufnr, ns, hunk, opts)

      local extmarks = get_extmarks(bufnr)
      local header_extmarks = 0
      for _, mark in ipairs(extmarks) do
        if mark[2] < 4 and mark[4] and mark[4].hl_group and mark[4].hl_group:match('^@') then
          header_extmarks = header_extmarks + 1
        end
      end
      assert.are.equal(0, header_extmarks)
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
        },
      }
    end

    it('uses priority 199 for code languages', function()
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
      local has_priority_199 = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group and mark[4].hl_group:match('^@.*%.lua$') then
          if mark[4].priority == 199 then
            has_priority_199 = true
            break
          end
        end
      end
      assert.is_true(has_priority_199)
      delete_buffer(bufnr)
    end)

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
