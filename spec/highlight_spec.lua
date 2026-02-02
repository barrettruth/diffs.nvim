require('spec.helpers')
local highlight = require('fugitive-ts.highlight')

describe('highlight', function()
  describe('highlight_hunk', function()
    local ns

    before_each(function()
      ns = vim.api.nvim_create_namespace('fugitive_ts_test')
      local diff_add = vim.api.nvim_get_hl(0, { name = 'DiffAdd' })
      local diff_delete = vim.api.nvim_get_hl(0, { name = 'DiffDelete' })
      vim.api.nvim_set_hl(0, 'FugitiveTsAdd', { bg = diff_add.bg })
      vim.api.nvim_set_hl(0, 'FugitiveTsDelete', { bg = diff_delete.bg })
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
        max_lines = 500,
        conceal_prefixes = false,
        highlights = {
          treesitter = true,
          background = false,
          linenr = false,
          vim = false,
        },
      }
      if overrides then
        for k, v in pairs(overrides) do
          if k == 'highlights' then
            for hk, hv in pairs(v) do
              opts.highlights[hk] = hv
            end
          else
            opts[k] = v
          end
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

    it('applies overlay extmarks when conceal_prefixes enabled', function()
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

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts({ conceal_prefixes = true }))

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

    it('does not apply overlay extmarks when conceal_prefixes disabled', function()
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

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts({ conceal_prefixes = false }))

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
        if mark[4] and mark[4].line_hl_group == 'FugitiveTsAdd' then
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
        if mark[4] and mark[4].line_hl_group == 'FugitiveTsDelete' then
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

    it('applies number_hl_group when linenr enabled', function()
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
        default_opts({ highlights = { background = true, linenr = true } })
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

    it('does not apply number_hl_group when linenr disabled', function()
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
        default_opts({ highlights = { background = true, linenr = false } })
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
        default_opts({ highlights = { treesitter = false, background = true } })
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
        default_opts({ highlights = { treesitter = false, background = true } })
      )

      local extmarks = get_extmarks(bufnr)
      local has_diff_add = false
      for _, mark in ipairs(extmarks) do
        if mark[4] and mark[4].line_hl_group == 'FugitiveTsAdd' then
          has_diff_add = true
          break
        end
      end
      assert.is_true(has_diff_add)
      delete_buffer(bufnr)
    end)
  end)
end)
