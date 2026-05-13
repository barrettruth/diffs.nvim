require('spec.helpers')
local config = require('diffs.config')

describe('diffs.config', function()
  describe('new', function()
    it('defaults view.prefix to true', function()
      local opts = config.new()
      assert.is_true(opts.view.prefix)
      assert.is_nil(opts.hide_prefix)
      assert.is_nil(opts.highlights.gutter)
      assert.is_nil(opts.highlights.priorities)
      assert.is_nil(opts.conflict.priority)
    end)

    it('keeps supported highlights config without removed fields', function()
      local opts = config.new({ highlights = { background = false, blend_alpha = 0.4 } })
      assert.is_false(opts.highlights.background)
      assert.are.equal(0.4, opts.highlights.blend_alpha)
      assert.is_nil(opts.highlights.priorities)
    end)

    it('keeps supported conflict config without removed priority', function()
      local opts = config.new({ conflict = { show_virtual_text = false } })
      assert.is_false(opts.conflict.show_virtual_text)
      assert.is_nil(opts.conflict.priority)
    end)

    it('rejects removed config keys', function()
      local cases = {
        {
          config = { hide_prefix = true },
          message = 'diffs: hide_prefix has been removed; use view.prefix',
        },
        {
          config = { highlights = { gutter = false } },
          message = 'diffs: highlights.gutter has been removed',
        },
        {
          config = { highlights = { priorities = { syntax = 250 } } },
          message = 'diffs: highlights.priorities has been removed',
        },
        {
          config = { conflict = { priority = 250 } },
          message = 'diffs: conflict.priority has been removed',
        },
      }

      for _, case in ipairs(cases) do
        local ok, err = pcall(config.new, case.config)
        assert.is_false(ok)
        assert.matches(case.message, err, 1, true)
      end
    end)

    it('keeps boolean integration toggles as the supported enable path', function()
      for _, key in ipairs({ 'fugitive', 'neogit', 'neojj', 'gitsigns', 'committia', 'telescope' }) do
        local opts = config.new({ integrations = { [key] = true } })
        assert.is_true(opts.integrations[key])
      end
    end)

    it('rejects removed integration table config', function()
      for _, key in ipairs({ 'fugitive', 'neogit', 'neojj', 'gitsigns', 'committia', 'telescope' }) do
        local ok, err = pcall(config.new, { integrations = { [key] = {} } })
        assert.is_false(ok)
        assert.matches('integrations.' .. key, err, 1, true)
        assert.matches('boolean', err, 1, true)
      end
    end)
  end)

  describe('with_internal_highlight_priorities', function()
    it('adds fixed priorities to hunk highlight options only', function()
      local highlights = { background = false }
      local hunk_highlights = config.with_internal_highlight_priorities(highlights)

      assert.is_nil(highlights.priorities)
      assert.are.same(
        { clear = 198, syntax = 199, line_bg = 200, char_bg = 201 },
        hunk_highlights.priorities
      )
      assert.is_false(hunk_highlights.background)
    end)
  end)

  describe('compute_filetypes', function()
    local compute = config.compute_filetypes

    it('returns core filetypes with empty config', function()
      local fts = compute({})
      assert.are.same({ 'git', 'gitcommit' }, fts)
    end)

    it('includes fugitive when integrations.fugitive = true', function()
      local fts = compute({ integrations = { fugitive = true } })
      assert.is_true(vim.tbl_contains(fts, 'fugitive'))
    end)

    it('excludes fugitive when integrations.fugitive is a table', function()
      local fts = compute({ integrations = { fugitive = {} } })
      assert.is_false(vim.tbl_contains(fts, 'fugitive'))
    end)

    it('excludes fugitive when integrations.fugitive = false', function()
      local fts = compute({ integrations = { fugitive = false } })
      assert.is_false(vim.tbl_contains(fts, 'fugitive'))
    end)

    it('excludes fugitive when integrations.fugitive is nil', function()
      local fts = compute({ integrations = {} })
      assert.is_false(vim.tbl_contains(fts, 'fugitive'))
    end)

    it('includes neogit filetypes when integrations.neogit = true', function()
      local fts = compute({ integrations = { neogit = true } })
      assert.is_true(vim.tbl_contains(fts, 'NeogitStatus'))
      assert.is_true(vim.tbl_contains(fts, 'NeogitCommitView'))
      assert.is_true(vim.tbl_contains(fts, 'NeogitDiffView'))
    end)

    it('excludes neogit filetypes when integrations.neogit is a table', function()
      local fts = compute({ integrations = { neogit = {} } })
      assert.is_false(vim.tbl_contains(fts, 'NeogitStatus'))
    end)

    it('excludes neogit when integrations.neogit = false', function()
      local fts = compute({ integrations = { neogit = false } })
      assert.is_false(vim.tbl_contains(fts, 'NeogitStatus'))
    end)

    it('excludes neogit when integrations.neogit is nil', function()
      local fts = compute({ integrations = {} })
      assert.is_false(vim.tbl_contains(fts, 'NeogitStatus'))
    end)

    it('includes extra_filetypes', function()
      local fts = compute({ extra_filetypes = { 'diff' } })
      assert.is_true(vim.tbl_contains(fts, 'diff'))
    end)

    it('combines integrations and extra_filetypes', function()
      local fts = compute({
        integrations = { fugitive = true, neogit = true },
        extra_filetypes = { 'diff' },
      })
      assert.is_true(vim.tbl_contains(fts, 'git'))
      assert.is_true(vim.tbl_contains(fts, 'fugitive'))
      assert.is_true(vim.tbl_contains(fts, 'NeogitStatus'))
      assert.is_true(vim.tbl_contains(fts, 'diff'))
    end)
  end)
end)
