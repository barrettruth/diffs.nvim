require('spec.helpers')
local config = require('diffs.config')
local highlight_groups = require('diffs.runtime.highlight_groups')
local stub = require('luassert.stub')

describe('conflict highlight groups', function()
  local source
  local groups

  before_each(function()
    source = {
      Normal = { fg = 0xe4e4ef, bg = 0x181818 },
      DiffAdd = { bg = 0x1a3a1a },
      diffAdded = { fg = 0x80d080 },
      diffRemoved = { fg = 0xd08080 },
      DiffChange = { fg = 0x80a0c0, bg = 0x565f73 },
      DiffText = { bg = 0x52494e },
    }
    groups = {}
    stub(vim.api, 'nvim_get_hl', function(_, opts)
      return source[opts.name] or {}
    end)
    stub(vim.api, 'nvim_set_hl', function(_, name, attrs)
      groups[name] = attrs
    end)
  end)

  after_each(function()
    vim.api.nvim_get_hl:revert()
    vim.api.nvim_set_hl:revert()
  end)

  it('uses the DiffText foreground for base line numbers', function()
    source.DiffText.fg = 0xe0a080

    highlight_groups.apply(config.new())

    assert.are.equal(source.DiffText.fg, groups.DiffsConflictBaseNr.fg)
    assert.are.equal(source.DiffChange.fg, groups.DiffsConflictTheirsNr.fg)
    assert.are.equal(source.diffAdded.fg, groups.DiffsConflictOursNr.fg)
    assert.are.equal(groups.DiffsConflictBase.bg, groups.DiffsConflictBaseNr.bg)
  end)

  it('falls back to the deletion foreground for background-only diff groups', function()
    source.DiffChange.fg = nil

    highlight_groups.apply(config.new())

    assert.are.equal(source.diffRemoved.fg, groups.DiffsConflictBaseNr.fg)
    assert.are.equal(0x80a0c0, groups.DiffsConflictTheirsNr.fg)
    assert.are.equal(source.diffAdded.fg, groups.DiffsConflictOursNr.fg)
    assert.are.equal(0x353033, groups.DiffsConflictBase.bg)
    assert.are.equal(groups.DiffsConflictBase.bg, groups.DiffsConflictBaseNr.bg)
  end)
end)
