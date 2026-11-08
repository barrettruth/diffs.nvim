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
      assert.are.same({}, config.new({}).integrations)
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
            treesitter = { max_lines = 1000 },
            vim = false,
            intra = {
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
      assert.is_table(opts.highlights.treesitter)
    end)

    it('accepts boolean and table highlight settings', function()
      for _, key in ipairs({ 'vim' }) do
        local defaults = config.new().highlights[key]
        for _, value in ipairs({ true, {} }) do
          assert.are.same(defaults, config.new({ highlights = { [key] = value } }).highlights[key])
        end
        assert.is_false(config.new({ highlights = { [key] = false } }).highlights[key])
        assert.are.same(
          vim.tbl_extend('force', defaults, { max_lines = 1000 }),
          config.new({ highlights = { [key] = { max_lines = 1000 } } }).highlights[key]
        )
      end
    end)

    it('defaults view.prefix to true', function()
      local opts = config.new()
      assert.is_true(opts.view.prefix)
      assert.is_nil(opts.hide_prefix)
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

    it('accepts boolean and table conflict settings', function()
      local defaults = config.new().conflict
      for _, value in ipairs({ true, {} }) do
        assert.are.same(defaults, config.new({ conflict = value }).conflict)
      end
      assert.is_false(config.new({ conflict = false }).conflict)
      assert.are.same(
        vim.tbl_extend('force', defaults, { keymaps = { ours = 'co' } }),
        config.new({ conflict = { keymaps = { ours = 'co' } } }).conflict
      )
    end)

    it('accepts integration lists and boolean maps', function()
      for _, key in ipairs(integration_keys) do
        for _, integrations in ipairs({ { key }, { [key] = true }, { [key] = false } }) do
          local input = vim.deepcopy(integrations)
          local opts = config.new({ integrations = integrations })
          assert.are.equal(integrations[key] ~= false, opts.integrations[key])
          assert.is_nil(opts.integrations[1])
          assert.are.same(input, integrations)
        end
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
      local ok, err = pcall(config.new, { integrations = { true } })
      assert.is_false(ok)
      assert.matches('integrations[1]', err, 1, true)
      assert.matches('string', err, 1, true)
    end)

    it('validates numeric highlight limits', function()
      local cases = {
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

    it('includes fugitive from integration lists and boolean maps', function()
      for _, integrations in ipairs({ { 'fugitive' }, { fugitive = true } }) do
        local fts = compute({ integrations = integrations })
        assert.is_true(vim.tbl_contains(fts, 'fugitive'))
      end
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
