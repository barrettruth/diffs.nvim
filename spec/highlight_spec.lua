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
      local add_lines = {}
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsAdd' then
          add_lines[mark[2]] = true
        end
      end
      assert.is_nil(add_lines[1])
      assert.is_true(add_lines[2] ~= nil)
      assert.is_true(add_lines[3] ~= nil)
      assert.is_true(add_lines[4] ~= nil)
      assert.is_true(add_lines[5] ~= nil)
      assert.is_true(add_lines[6] ~= nil)
      assert.is_true(add_lines[7] ~= nil)
      assert.is_nil(add_lines[8])
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
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].hl_group == 'DiffsClear' then
          assert.are.equal(2, mark[3])
        end
      end
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
