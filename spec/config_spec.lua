require('spec.helpers')
local config = require('diffs.config')

describe('diffs.config', function()
  local default_priorities = { clear = 198, syntax = 199, line_bg = 200, char_bg = 201 }

  local function capture_notifications(fn)
    local saved_notify = vim.notify
    local notifications = {}
    vim.notify = function(message, level)
      notifications[#notifications + 1] = { message = message, level = level }
    end
    local ok, result = pcall(fn)
    vim.notify = saved_notify
    return ok, result, notifications
  end

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
          highlights = {
            background = true,
            treesitter = {
              enabled = true,
              max_lines = 1000,
            },
            vim = {
              enabled = false,
              max_lines = 200,
            },
          },
        })
      end)
    end)

    it('accepts partial config', function()
      assert.has_no.errors(function()
        config.new({
          view = {
            prefix = false,
          },
        })
      end)
    end)

    it('defaults view.prefix to true', function()
      local opts = config.new()
      assert.is_true(opts.view.prefix)
      assert.is_nil(opts.hide_prefix)
    end)

    it('warns and maps deprecated hide_prefix = true to view.prefix = false', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, { hide_prefix = true })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_false(opts.view.prefix)
      assert.is_nil(opts.hide_prefix)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.hide_prefix is deprecated, use vim.g.diffs.view.prefix instead.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
    end)

    it('warns and maps deprecated hide_prefix = false to view.prefix = true', function()
      local saved_deprecate = vim.deprecate
      vim.deprecate = function() end

      local ok, opts = pcall(config.new, { hide_prefix = false })
      vim.deprecate = saved_deprecate

      assert.is_true(ok)
      assert.is_true(opts.view.prefix)
      assert.is_nil(opts.hide_prefix)
    end)

    it('keeps view.prefix when deprecated hide_prefix is also set', function()
      local saved_deprecate = vim.deprecate
      vim.deprecate = function() end

      local ok, opts = pcall(config.new, { hide_prefix = true, view = { prefix = true } })
      vim.deprecate = saved_deprecate

      assert.is_true(ok)
      assert.is_true(opts.view.prefix)
      assert.is_nil(opts.hide_prefix)
    end)

    it('leaves deprecated highlights.gutter unset by default', function()
      local opts = config.new()
      assert.is_nil(opts.highlights.gutter)
    end)

    it('warns when deprecated highlights.gutter is set', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, err = pcall(config.new, { highlights = { gutter = false } })
      vim.notify = saved_notify

      assert.is_true(ok, err)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.highlights.gutter is deprecated.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
    end)

    it('warns and drops deprecated highlights.priorities values', function()
      local ok, opts, notifications = capture_notifications(function()
        return config.new({
          highlights = {
            priorities = { clear = 10, syntax = 20, line_bg = 30, char_bg = 40 },
          },
        })
      end)

      assert.is_true(ok)
      assert.are.same(default_priorities, opts.highlights.priorities)
      assert.are.equal(2, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.highlights.priorities.{clear,syntax,line_bg,char_bg} is deprecated.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(
        notifications[2].message:find("in function 'deprecate_highlight_priorities'", 1, true)
      )
    end)

    it('warns and drops an empty deprecated highlights.priorities table', function()
      local saved_deprecate = vim.deprecate
      local calls = {}
      vim.deprecate = function(name, alternative, version, plugin)
        calls[#calls + 1] = { name, alternative, version, plugin }
      end

      local ok, opts = pcall(config.new, {
        highlights = {
          priorities = {},
        },
      })
      vim.deprecate = saved_deprecate

      assert.is_true(ok)
      assert.are.same(default_priorities, opts.highlights.priorities)
      assert.are.equal(1, #calls)
      assert.are.equal(
        'vim.g.diffs.highlights.priorities.{clear,syntax,line_bg,char_bg}',
        calls[1][1]
      )
      assert.is_nil(calls[1][2])
      assert.are.equal('0.4.0', calls[1][3])
      assert.are.equal('diffs.nvim', calls[1][4])
    end)

    it('keeps supported highlights config without priorities quiet', function()
      local ok, opts, notifications = capture_notifications(function()
        return config.new({ highlights = { background = false, blend_alpha = 0.4 } })
      end)

      assert.is_true(ok)
      assert.is_false(opts.highlights.background)
      assert.are.equal(0.4, opts.highlights.blend_alpha)
      assert.are.same(default_priorities, opts.highlights.priorities)
      assert.are.equal(0, #notifications)
    end)

    it('validates deprecated highlights.priorities before warning', function()
      for _, key in ipairs({ 'clear', 'syntax', 'line_bg', 'char_bg' }) do
        local ok, err, notifications = capture_notifications(function()
          return config.new({
            highlights = {
              priorities = { [key] = -1 },
            },
          })
        end)

        assert.is_false(ok)
        assert.matches('diffs: highlights.priorities.' .. key .. ' must be >= 0', err, 1, true)
        assert.are.equal(0, #notifications)
      end
    end)

    it('type-checks deprecated highlights.priorities before warning', function()
      local ok, err, notifications = capture_notifications(function()
        return config.new({ highlights = { priorities = false } })
      end)

      assert.is_false(ok)
      assert.matches('highlights.priorities', err, 1, true)
      assert.matches('table', err, 1, true)
      assert.are.equal(0, #notifications)

      for _, key in ipairs({ 'clear', 'syntax', 'line_bg', 'char_bg' }) do
        ok, err, notifications = capture_notifications(function()
          return config.new({
            highlights = {
              priorities = { [key] = 'bad' },
            },
          })
        end)

        assert.is_false(ok)
        assert.matches('highlights.priorities.' .. key, err, 1, true)
        assert.matches('number', err, 1, true)
        assert.are.equal(0, #notifications)
      end
    end)

    it('warns and drops deprecated conflict.priority', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, { conflict = { priority = 250 } })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_nil(opts.conflict.priority)
      assert.are.equal(2, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.conflict.priority is deprecated.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(notifications[2].message:find("in function 'deprecate_conflict'", 1, true))
    end)

    it('keeps supported conflict config without priority quiet', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, { conflict = { show_virtual_text = false } })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_false(opts.conflict.show_virtual_text)
      assert.is_nil(opts.conflict.priority)
      assert.are.equal(0, #notifications)
    end)

    it('validates deprecated conflict.priority before warning', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, err = pcall(config.new, { conflict = { priority = -1 } })
      vim.notify = saved_notify

      assert.is_false(ok)
      assert.matches('diffs: conflict.priority must be >= 0', err, 1, true)
      assert.are.equal(0, #notifications)
    end)

    it('type-checks deprecated conflict.priority before warning', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, err = pcall(config.new, { conflict = { priority = 'bad' } })
      vim.notify = saved_notify

      assert.is_false(ok)
      assert.matches('conflict.priority', err, 1, true)
      assert.matches('number', err, 1, true)
      assert.are.equal(0, #notifications)
    end)

    it('keeps integrations.fugitive = true as the supported enable path', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local opts = config.new({ integrations = { fugitive = true } })
      vim.notify = saved_notify

      assert.is_true(opts.integrations.fugitive)
      assert.are.equal(0, #notifications)
    end)

    it('warns and maps deprecated integrations.fugitive table form to true', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, {
        integrations = {
          fugitive = {},
        },
      })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_true(opts.integrations.fugitive)
      assert.are.equal(2, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.integrations.fugitive = { ... } is deprecated, use vim.g.diffs.integrations.fugitive = true instead.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(notifications[2].message:find("in function 'migrate_fugitive'", 1, true))
      assert.is_not_nil(
        notifications[2].message:find("in function 'normalize_integrations'", 1, true)
      )
    end)

    it('warns and maps deprecated fugitive keymap config to true', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, {
        integrations = {
          fugitive = {
            horizontal = 'dd',
            vertical = false,
          },
        },
      })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_true(opts.integrations.fugitive)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.integrations.fugitive.{horizontal,vertical} is deprecated.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(
        notifications[2].message:find("in function 'deprecate_fugitive_keymaps'", 1, true)
      )
    end)

    it('keeps integrations.neogit = true as the supported enable path', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local opts = config.new({ integrations = { neogit = true } })
      vim.notify = saved_notify

      assert.is_true(opts.integrations.neogit)
      assert.are.equal(0, #notifications)
    end)

    it('warns and maps deprecated integrations.neogit table form to true', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, {
        integrations = {
          neogit = {},
        },
      })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_true(opts.integrations.neogit)
      assert.are.equal(2, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.integrations.neogit = { ... } is deprecated, use vim.g.diffs.integrations.neogit = true instead.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(notifications[2].message:find("in function 'migrate_neogit'", 1, true))
      assert.is_not_nil(
        notifications[2].message:find("in function 'normalize_integrations'", 1, true)
      )
    end)

    it('keeps integrations.neojj = true as the supported enable path', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local opts = config.new({ integrations = { neojj = true } })
      vim.notify = saved_notify

      assert.is_true(opts.integrations.neojj)
      assert.are.equal(0, #notifications)
    end)

    it('warns and maps deprecated integrations.neojj table form to true', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, {
        integrations = {
          neojj = {},
        },
      })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_true(opts.integrations.neojj)
      assert.are.equal(2, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.integrations.neojj = { ... } is deprecated, use vim.g.diffs.integrations.neojj = true instead.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(notifications[2].message:find("in function 'migrate_neojj'", 1, true))
      assert.is_not_nil(
        notifications[2].message:find("in function 'normalize_integrations'", 1, true)
      )
    end)

    it('keeps integrations.gitsigns = true as the supported enable path', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local opts = config.new({ integrations = { gitsigns = true } })
      vim.notify = saved_notify

      assert.is_true(opts.integrations.gitsigns)
      assert.are.equal(0, #notifications)
    end)

    it('warns and maps deprecated integrations.gitsigns table form to true', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, {
        integrations = {
          gitsigns = {},
        },
      })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_true(opts.integrations.gitsigns)
      assert.are.equal(2, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.integrations.gitsigns = { ... } is deprecated, use vim.g.diffs.integrations.gitsigns = true instead.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(notifications[2].message:find("in function 'migrate_gitsigns'", 1, true))
      assert.is_not_nil(
        notifications[2].message:find("in function 'normalize_integrations'", 1, true)
      )
    end)

    it('keeps integrations.committia = true as the supported enable path', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local opts = config.new({ integrations = { committia = true } })
      vim.notify = saved_notify

      assert.is_true(opts.integrations.committia)
      assert.are.equal(0, #notifications)
    end)

    it('warns and maps deprecated integrations.committia table form to true', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, {
        integrations = {
          committia = {},
        },
      })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_true(opts.integrations.committia)
      assert.are.equal(2, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.integrations.committia = { ... } is deprecated, use vim.g.diffs.integrations.committia = true instead.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(notifications[2].message:find("in function 'migrate_committia'", 1, true))
      assert.is_not_nil(
        notifications[2].message:find("in function 'normalize_integrations'", 1, true)
      )
    end)

    it('keeps integrations.telescope = true as the supported enable path', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local opts = config.new({ integrations = { telescope = true } })
      vim.notify = saved_notify

      assert.is_true(opts.integrations.telescope)
      assert.are.equal(0, #notifications)
    end)

    it('warns and maps deprecated non-empty integrations.telescope table form to true', function()
      local saved_notify = vim.notify
      local notifications = {}
      vim.notify = function(message, level)
        notifications[#notifications + 1] = { message = message, level = level }
      end

      local ok, opts = pcall(config.new, {
        integrations = {
          telescope = { enabled = false },
        },
      })
      vim.notify = saved_notify

      assert.is_true(ok)
      assert.is_true(opts.integrations.telescope)
      assert.are.equal(2, #notifications)
      assert.are.equal(vim.log.levels.WARN, notifications[1].level)
      assert.are.equal(
        'vim.g.diffs.integrations.telescope = { ... } is deprecated, use vim.g.diffs.integrations.telescope = true instead.\n'
          .. 'Feature will be removed in diffs.nvim 0.4.0',
        notifications[1].message
      )
      assert.are.equal(vim.log.levels.WARN, notifications[2].level)
      assert.is_true(notifications[2].message:find('stack traceback:\n\t', 1, true) == 1)
      assert.is_not_nil(notifications[2].message:find('lua/diffs/config.lua:', 1, true))
      assert.is_not_nil(notifications[2].message:find("in function 'migrate_telescope'", 1, true))
      assert.is_not_nil(
        notifications[2].message:find("in function 'normalize_integrations'", 1, true)
      )
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

    it('includes fugitive during deprecated table-form window', function()
      local fts = compute({ integrations = { fugitive = {} } })
      assert.is_true(vim.tbl_contains(fts, 'fugitive'))
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

    it('includes neogit filetypes when integrations.neogit is a table', function()
      local fts = compute({ integrations = { neogit = {} } })
      assert.is_true(vim.tbl_contains(fts, 'NeogitStatus'))
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
