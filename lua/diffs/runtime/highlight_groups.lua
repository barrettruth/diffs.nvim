local log = require('diffs.log')

local M = {}

---@param hex integer
---@param bg_hex integer
---@param alpha number
---@return integer
local function blend_color(hex, bg_hex, alpha)
  ---@diagnostic disable: undefined-global
  local r = bit.band(bit.rshift(hex, 16), 0xFF)
  local g = bit.band(bit.rshift(hex, 8), 0xFF)
  local b = bit.band(hex, 0xFF)

  local bg_r = bit.band(bit.rshift(bg_hex, 16), 0xFF)
  local bg_g = bit.band(bit.rshift(bg_hex, 8), 0xFF)
  local bg_b = bit.band(bg_hex, 0xFF)

  local blend_r = math.floor(r * alpha + bg_r * (1 - alpha))
  local blend_g = math.floor(g * alpha + bg_g * (1 - alpha))
  local blend_b = math.floor(b * alpha + bg_b * (1 - alpha))

  return bit.bor(bit.lshift(blend_r, 16), bit.lshift(blend_g, 8), blend_b)
  ---@diagnostic enable: undefined-global
end

---@param name string
---@return table
local function resolve_hl(name)
  local hl = vim.api.nvim_get_hl(0, { name = name })
  while hl.link do
    hl = vim.api.nvim_get_hl(0, { name = hl.link })
  end
  return hl
end

---@param config diffs.Config
---@param is_default? boolean
---@return { transparent: boolean }
function M.apply(config, is_default)
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
  local diff_add = vim.api.nvim_get_hl(0, { name = 'DiffAdd' })
  local diff_delete = vim.api.nvim_get_hl(0, { name = 'DiffDelete' })
  local diff_added = resolve_hl('diffAdded')
  local diff_removed = resolve_hl('diffRemoved')

  local dark = vim.o.background ~= 'light'
  local transparent = not normal.bg
  local bg = normal.bg or (dark and 0x1a1a1a or 0xf0f0f0)
  local add_bg = diff_add.bg or (dark and 0x1a3a1a or 0xd0ffd0)
  local del_bg = diff_delete.bg or (dark and 0x3a1a1a or 0xffd0d0)
  local add_fg = diff_added.fg or diff_add.fg or (dark and 0x80d080 or 0x206020)
  local del_fg = diff_removed.fg or diff_delete.fg or (dark and 0xd08080 or 0x802020)

  local dflt = is_default or false
  local normal_fg = normal.fg or (dark and 0xcccccc or 0x333333)

  local alpha = config.highlights.blend_alpha or 0.6
  local blended_add = blend_color(add_bg, bg, alpha)
  local blended_del = blend_color(del_bg, bg, alpha)
  local blended_add_text = add_bg
  local blended_del_text = del_bg

  local clear_hl = { default = dflt, fg = normal_fg }
  if not transparent then
    clear_hl.bg = bg
  end
  vim.api.nvim_set_hl(0, 'DiffsClear', clear_hl)
  vim.api.nvim_set_hl(0, 'DiffsAdd', { default = dflt, bg = blended_add })
  vim.api.nvim_set_hl(0, 'DiffsDelete', { default = dflt, bg = blended_del })
  vim.api.nvim_set_hl(0, 'DiffsAddNr', { default = dflt, fg = add_fg, bg = blended_add })
  vim.api.nvim_set_hl(0, 'DiffsDeleteNr', { default = dflt, fg = del_fg, bg = blended_del })
  vim.api.nvim_set_hl(0, 'DiffsAddText', { default = dflt, bg = blended_add_text })
  vim.api.nvim_set_hl(0, 'DiffsDeleteText', { default = dflt, bg = blended_del_text })

  log.dbg(
    'highlight groups: Normal.bg=%s DiffAdd.bg=#%06x diffAdded.fg=#%06x',
    normal.bg and string.format('#%06x', normal.bg) or 'NONE',
    add_bg,
    add_fg
  )
  log.dbg(
    'DiffsAdd.bg=#%06x DiffsAddText.bg=#%06x DiffsAddNr.fg=#%06x',
    blended_add,
    blended_add_text,
    add_fg
  )
  log.dbg('DiffsDelete.bg=#%06x DiffsDeleteText.bg=#%06x', blended_del, blended_del_text)

  local diff_change = resolve_hl('DiffChange')
  local diff_text = resolve_hl('DiffText')

  vim.api.nvim_set_hl(0, 'DiffsDiffAdd', { default = dflt, bg = diff_add.bg })
  vim.api.nvim_set_hl(
    0,
    'DiffsDiffDelete',
    { default = dflt, fg = diff_delete.fg, bg = diff_delete.bg }
  )
  vim.api.nvim_set_hl(0, 'DiffsDiffChange', { default = dflt, bg = diff_change.bg })
  vim.api.nvim_set_hl(0, 'DiffsDiffText', { default = dflt, bg = diff_text.bg })

  local change_bg = diff_change.bg or 0x3a3a4a
  local text_bg = diff_text.bg or 0x4a4a5a
  local change_fg = diff_change.fg or diff_text.fg or 0x80a0c0

  local base_alpha = math.max(alpha - 0.1, 0.0)
  local blended_ours = blend_color(add_bg, bg, alpha)
  local blended_theirs = blend_color(change_bg, bg, alpha)
  local blended_base = blend_color(text_bg, bg, base_alpha)
  local blended_ours_nr = add_fg
  local blended_theirs_nr = change_fg
  local blended_base_nr = change_fg

  vim.api.nvim_set_hl(0, 'DiffsConflictOurs', { default = dflt, bg = blended_ours })
  vim.api.nvim_set_hl(0, 'DiffsConflictTheirs', { default = dflt, bg = blended_theirs })
  vim.api.nvim_set_hl(0, 'DiffsConflictBase', { default = dflt, bg = blended_base })
  vim.api.nvim_set_hl(0, 'DiffsConflictMarker', { default = dflt, fg = 0x808080, bold = true })
  vim.api.nvim_set_hl(0, 'DiffsConflictActions', { default = dflt, fg = 0x808080 })
  vim.api.nvim_set_hl(
    0,
    'DiffsConflictOursNr',
    { default = dflt, fg = blended_ours_nr, bg = blended_ours }
  )
  vim.api.nvim_set_hl(
    0,
    'DiffsConflictTheirsNr',
    { default = dflt, fg = blended_theirs_nr, bg = blended_theirs }
  )
  vim.api.nvim_set_hl(
    0,
    'DiffsConflictBaseNr',
    { default = dflt, fg = blended_base_nr, bg = blended_base }
  )

  if config.highlights.overrides then
    for group, hl in pairs(config.highlights.overrides) do
      vim.api.nvim_set_hl(0, group, hl)
    end
  end

  return { transparent = transparent }
end

return M
