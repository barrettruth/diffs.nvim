require('spec.helpers')
local config = require('diffs.config')

describe('diffs.config', function()
  local integration_keys = { 'fugitive', 'neogit', 'neojj', 'gitsigns', 'committia', 'telescope' }

  describe('new', function()
    it('accepts nil config', function()
      assert.has_no.errors(function()
        config.new()
      end)
    end)

    it('accepts empty config', function()
      assert.has_no.errors(function()
        config.new({})
      end)
    end)

    it('accepts full config', function()
      assert.has_no.errors(function()
        config.new({
          debug = true,
          view = {
            prefix = true,
          },
          extra_filetypes = { 'diff' },
          highlights = {
            background = true,
            blend_alpha = 0.4,
            warn_max_lines = false,
            context = {
              enabled = false,
              lines = 10,
            },
            treesitter = {
              enabled = true,
              max_lines = 1000,
            },
            vim = {
              enabled = false,
              max_lines = 200,
            },
            intra = {
              enabled = true,
              algorithm = 'vscode',
              max_lines = 250,
            },
          },
          integrations = {
            fugitive = true,
            neogit = true,
            neojj = true,
            gitsigns = true,
            committia = true,
            telescope = true,
          },
          conflict = {
            enabled = true,
            disable_diagnostics = false,
            show_virtual_text = true,
            format_virtual_text = function()
              return nil
            end,
            show_actions = true,
            keymaps = {
              ours = 'co',
              theirs = 'ct',
              both = 'cb',
              none = 'c0',
              next = ']x',
              prev = '[x',
            },
          },
        })
      end)
    end)

    it('accepts partial config', function()
      local opts = config.new({
        view = {
          prefix = false,
        },
        highlights = {
          background = false,
        },
      })

      assert.is_false(opts.view.prefix)
      assert.is_false(opts.highlights.background)
      assert.is_true(opts.highlights.treesitter.enabled)
    end)

    it('defaults view.prefix to true', function()
      local opts = config.new()
      assert.is_true(opts.view.prefix)
      assert.is_nil(opts.hide_prefix)
    end)

    it('defaults view glyphs', function()
      local opts = config.new()
      assert.are.equal('▏', opts.view.change_bar)
      assert.are.equal('│', opts.view.rail_separator)
    end)

    it('defaults view.default_layout to unified', function()
      local opts = config.new()
      assert.are.equal('unified', opts.view.default_layout)
    end)

    it('accepts supported default layouts', function()
      for _, layout in ipairs({ 'unified', 'stacked', 'split' }) do
        local opts = config.new({ view = { default_layout = layout } })
        assert.are.equal(layout, opts.view.default_layout)
      end
    end)

    it('rejects unsupported default layouts', function()
      local ok, err = pcall(config.new, { view = { default_layout = 'tiled' } })
      assert.is_false(ok)
      assert.matches('view.default_layout', err, 1, true)
      assert.matches("'unified', 'stacked', or 'split'", err, 1, true)
    end)

    it('accepts custom view glyphs', function()
      local opts = config.new({
        view = {
          change_bar = '┃',
          rail_separator = '|',
        },
      })
      assert.are.equal('┃', opts.view.change_bar)
      assert.are.equal('|', opts.view.rail_separator)
    end)

    it('validates custom view glyphs', function()
      local ok, err = pcall(config.new, { view = { change_bar = false } })
      assert.is_false(ok)
      assert.matches('view.change_bar', err, 1, true)
      assert.matches('string', err, 1, true)

      ok, err = pcall(config.new, { view = { rail_separator = false } })
      assert.is_false(ok)
      assert.matches('view.rail_separator', err, 1, true)
      assert.matches('string', err, 1, true)
    end)

    it('defaults supported config without removed fields', function()
      local opts = config.new()

      assert.is_true(opts.view.prefix)
      assert.is_nil(opts.hide_prefix)
      assert.is_nil(opts.highlights.gutter)
      assert.is_nil(opts.highlights.priorities)
      assert.is_nil(opts.conflict.priority)
    end)

    it('keeps supported highlights config without removed priorities', function()
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
          input = { hide_prefix = true },
          message = 'diffs: hide_prefix has been removed; use view.prefix',
        },
        {
          input = { highlights = { gutter = false } },
          message = 'diffs: highlights.gutter has been removed',
        },
        {
          input = { highlights = { priorities = { syntax = 250 } } },
          message = 'diffs: highlights.priorities has been removed',
        },
        {
          input = { conflict = { priority = 250 } },
          message = 'diffs: conflict.priority has been removed',
        },
      }

      for _, case in ipairs(cases) do
        local ok, err = pcall(config.new, case.input)
        assert.is_false(ok)
        assert.matches(case.message, err, 1, true)
      end
    end)

    it('keeps boolean integration toggles as the supported enable path', function()
      for _, key in ipairs(integration_keys) do
        local opts = config.new({ integrations = { [key] = true } })
        assert.is_true(opts.integrations[key])
      end
    end)

    it('rejects removed integration table config', function()
      for _, key in ipairs(integration_keys) do
        local ok, err = pcall(config.new, { integrations = { [key] = {} } })
        assert.is_false(ok)
        assert.matches('integrations.' .. key, err, 1, true)
        assert.matches('boolean', err, 1, true)
      end
    end)

    it('rejects invalid integration value types', function()
      for _, key in ipairs(integration_keys) do
        local ok, err = pcall(config.new, { integrations = { [key] = 'yes' } })
        assert.is_false(ok)
        assert.matches('integrations.' .. key, err, 1, true)
        assert.matches('boolean', err, 1, true)
      end
    end)

    it('validates numeric highlight limits', function()
      local cases = {
        {
          input = { highlights = { context = { lines = -1 } } },
          message = 'diffs: highlights.context.lines must be >= 0',
        },
        {
          input = { highlights = { treesitter = { max_lines = 0 } } },
          message = 'diffs: highlights.treesitter.max_lines must be >= 1',
        },
        {
          input = { highlights = { vim = { max_lines = 0 } } },
          message = 'diffs: highlights.vim.max_lines must be >= 1',
        },
        {
          input = { highlights = { intra = { max_lines = 0 } } },
          message = 'diffs: highlights.intra.max_lines must be >= 1',
        },
        {
          input = { highlights = { blend_alpha = 2 } },
          message = 'diffs: highlights.blend_alpha must be >= 0 and <= 1',
        },
      }

      for _, case in ipairs(cases) do
        local ok, err = pcall(config.new, case.input)
        assert.is_false(ok)
        assert.matches(case.message, err, 1, true)
      end
    end)

    it('validates intra diff algorithm names', function()
      local ok, err = pcall(config.new, {
        highlights = {
          intra = {
            algorithm = 'other',
          },
        },
      })

      assert.is_false(ok)
      assert.matches('highlights.intra.algorithm', err, 1, true)
      assert.matches('default', err, 1, true)
      assert.matches('vscode', err, 1, true)
    end)

    it('validates conflict keymap values', function()
      local ok, err = pcall(config.new, {
        conflict = {
          keymaps = {
            ours = true,
          },
        },
      })

      assert.is_false(ok)
      assert.matches('conflict.keymaps.ours', err, 1, true)
      assert.matches('string or false', err, 1, true)
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
