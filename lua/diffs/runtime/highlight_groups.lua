local integrations = require('diffs.integrations')
local log = require('diffs.log')

local M = {}

---@param name string
---@return table
local function resolve_hl(name)
  return vim.api.nvim_get_hl(0, { name = name, link = false })
end

---@param config diffs.Config
---@param is_default? boolean
---@return { transparent: boolean }
function M.apply(config, is_default)
  local normal = resolve_hl('Normal')
  local diff_add = resolve_hl('DiffAdd')
  local diff_delete = resolve_hl('DiffDelete')
  local line_nr = resolve_hl('LineNr')
  local diff_added = resolve_hl('diffAdded')
  local diff_removed = resolve_hl('diffRemoved')
  local diff_change = resolve_hl('DiffChange')
  local diff_text = resolve_hl('DiffText')

  local dark = vim.o.background ~= 'light'
  local transparent = not normal.bg
  local bg = normal.bg or (dark and 0x1a1a1a or 0xf0f0f0)
  local add_bg = diff_add.bg or (dark and 0x1a3a1a or 0xd0ffd0)
  local del_bg = diff_delete.bg or (dark and 0x3a1a1a or 0xffd0d0)
  local add_fg = diff_added.fg or diff_add.fg or (dark and 0x80d080 or 0x206020)
  local del_fg = diff_removed.fg or diff_delete.fg or (dark and 0xd08080 or 0x802020)

  local dflt = is_default or false
  local normal_fg = normal.fg or (dark and 0xcccccc or 0x333333)
  local line_nr_fg = line_nr.fg or normal_fg
  local change_bg = diff_change.bg or 0x3a3a4a
  local text_bg = diff_text.bg or 0x4a4a5a
  local change_fg = diff_change.fg or diff_text.fg or 0x80a0c0

  local clear_hl = { default = dflt, fg = normal_fg }
  if not transparent then
    clear_hl.bg = bg
  end
  local rail_hl = { default = dflt, fg = normal_fg, nocombine = true }
  if not transparent then
    rail_hl.bg = bg
  end
  vim.api.nvim_set_hl(0, 'DiffsClear', clear_hl)
  vim.api.nvim_set_hl(0, 'DiffsAdd', { default = dflt, bg = add_bg })
  vim.api.nvim_set_hl(0, 'DiffsDelete', { default = dflt, bg = del_bg })
  vim.api.nvim_set_hl(0, 'DiffsRail', rail_hl)
  vim.api.nvim_set_hl(
    0,
    'DiffsRailNr',
    { default = dflt, fg = line_nr_fg, bg = bg, nocombine = true }
  )
  vim.api.nvim_set_hl(
    0,
    'DiffsAddRailNr',
    { default = dflt, fg = add_fg, bg = add_bg, nocombine = true }
  )
  vim.api.nvim_set_hl(
    0,
    'DiffsDeleteRailNr',
    { default = dflt, fg = del_fg, bg = del_bg, nocombine = true }
  )
  vim.api.nvim_set_hl(0, 'DiffsAddBar', { default = dflt, fg = add_fg, bg = add_bg })
  vim.api.nvim_set_hl(0, 'DiffsDeleteBar', { default = dflt, fg = del_fg, bg = del_bg })
  vim.api.nvim_set_hl(0, 'DiffsAddCount', { default = dflt, fg = add_fg })
  vim.api.nvim_set_hl(0, 'DiffsDeleteCount', { default = dflt, fg = del_fg })
  vim.api.nvim_set_hl(0, 'DiffsAddText', { default = dflt, bg = text_bg })
  vim.api.nvim_set_hl(0, 'DiffsDeleteText', { default = dflt, bg = text_bg })

  vim.api.nvim_set_hl(0, 'DiffsDim', { default = dflt, bg = resolve_hl('CursorLine').bg })

  log.dbg(
    'highlight groups: Normal.bg=%s DiffAdd.bg=#%06x diffAdded.fg=#%06x',
    normal.bg and string.format('#%06x', normal.bg) or 'NONE',
    add_bg,
    add_fg
  )
  log.dbg('DiffsAdd.bg=#%06x DiffsAddText.bg=#%06x', add_bg, text_bg)
  log.dbg('DiffsDelete.bg=#%06x DiffsDeleteText.bg=#%06x', del_bg, text_bg)

  vim.api.nvim_set_hl(0, 'DiffsDiffAdd', { default = dflt, bg = diff_add.bg })
  vim.api.nvim_set_hl(
    0,
    'DiffsDiffDelete',
    { default = dflt, fg = diff_delete.fg, bg = diff_delete.bg }
  )
  vim.api.nvim_set_hl(0, 'DiffsDiffChange', { default = dflt, bg = diff_change.bg })
  vim.api.nvim_set_hl(0, 'DiffsDiffText', { default = dflt, bg = diff_text.bg })
  vim.api.nvim_set_hl(0, 'DiffsDiffOff', {})

  vim.api.nvim_set_hl(0, 'DiffsConflictOurs', { default = dflt, bg = add_bg })
  vim.api.nvim_set_hl(0, 'DiffsConflictTheirs', { default = dflt, bg = change_bg })
  vim.api.nvim_set_hl(0, 'DiffsConflictBase', { default = dflt, bg = text_bg })
  vim.api.nvim_set_hl(0, 'DiffsConflictMarker', { default = dflt, fg = 0x808080, bold = true })
  vim.api.nvim_set_hl(0, 'DiffsConflictOursNr', { default = dflt, fg = add_fg, bg = add_bg })
  vim.api.nvim_set_hl(
    0,
    'DiffsConflictTheirsNr',
    { default = dflt, fg = change_fg, bg = change_bg }
  )
  vim.api.nvim_set_hl(0, 'DiffsConflictBaseNr', { default = dflt, fg = change_fg, bg = text_bg })

  -- Neogit's word-diff highlights changed words with these groups; when our
  -- integration owns the buffer we paint intra-line ourselves, so clear them.
  -- https://github.com/NeogitOrg/neogit/blob/99326a1310fb2d616b455d2fd16d01bf00682f06/lua/neogit/lib/diff_highlights.lua#L232-L233
  if integrations.is_enabled(config.integrations.neogit) then
    vim.api.nvim_set_hl(0, 'NeogitDiffAddInline', {})
    vim.api.nvim_set_hl(0, 'NeogitDiffDeleteInline', {})
  end

  if config.highlights.overrides then
    for group, hl in pairs(config.highlights.overrides) do
      vim.api.nvim_set_hl(0, group, hl)
    end
  end

  return { transparent = transparent }
end

return M
