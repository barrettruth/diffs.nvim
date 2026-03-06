local M = {}

local api = vim.api
local fn = vim.fn
local dbg = require('diffs.log').dbg

local ns = api.nvim_create_namespace('diffs-gitsigns')
local gs_popup_ns = api.nvim_create_namespace('gitsigns_popup')

local patched = false

---@param bufnr integer
---@param src_filename string
---@param src_ft string?
---@param src_lang string?
---@return diffs.Hunk[]
function M.parse_blame_hunks(bufnr, src_filename, src_ft, src_lang)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local hunks = {}
  local hunk_lines = {}
  local hunk_start = nil

  for i, line in ipairs(lines) do
    if line:match('^Hunk %d+ of %d+') then
      if hunk_start and #hunk_lines > 0 then
        table.insert(hunks, {
          filename = src_filename,
          ft = src_ft,
          lang = src_lang,
          start_line = hunk_start,
          prefix_width = 1,
          quote_width = 0,
          lines = hunk_lines,
        })
      end
      hunk_lines = {}
      hunk_start = i
    elseif hunk_start then
      if line:match('^%(guessed:') then
        hunk_start = i
      else
        local prefix = line:sub(1, 1)
        if prefix == ' ' or prefix == '+' or prefix == '-' then
          if #hunk_lines == 0 then
            hunk_start = i - 1
          end
          table.insert(hunk_lines, line)
        end
      end
    end
  end

  if hunk_start and #hunk_lines > 0 then
    table.insert(hunks, {
      filename = src_filename,
      ft = src_ft,
      lang = src_lang,
      start_line = hunk_start,
      prefix_width = 1,
      quote_width = 0,
      lines = hunk_lines,
    })
  end

  return hunks
end

---@param preview_winid integer
---@param preview_bufnr integer
local function on_preview(preview_winid, preview_bufnr)
  local ok, err = pcall(function()
    if not api.nvim_buf_is_valid(preview_bufnr) then
      return
    end
    if not api.nvim_win_is_valid(preview_winid) then
      return
    end

    local win = api.nvim_get_current_win()
    if win == preview_winid then
      win = fn.win_getid(fn.winnr('#'))
    end
    if win == -1 or win == 0 or not api.nvim_win_is_valid(win) then
      return
    end

    local srcbuf = api.nvim_win_get_buf(win)
    if not api.nvim_buf_is_loaded(srcbuf) then
      return
    end

    local ft = vim.bo[srcbuf].filetype
    local name = api.nvim_buf_get_name(srcbuf)
    if not name or name == '' then
      name = ft and ('a.' .. ft) or 'unknown'
    end
    local lang = ft and require('diffs.parser').get_lang_from_ft(ft) or nil

    local hunks = M.parse_blame_hunks(preview_bufnr, name, ft, lang)
    if #hunks == 0 then
      return
    end

    local diff_start = hunks[1].start_line
    local last = hunks[#hunks]
    local diff_end = last.start_line + #last.lines

    api.nvim_buf_clear_namespace(preview_bufnr, gs_popup_ns, diff_start, diff_end)
    api.nvim_buf_clear_namespace(preview_bufnr, ns, diff_start, diff_end)

    local opts = require('diffs').get_highlight_opts()
    local highlight = require('diffs.highlight')
    for _, hunk in ipairs(hunks) do
      highlight.highlight_hunk(preview_bufnr, ns, hunk, opts)
      for j, line in ipairs(hunk.lines) do
        local ch = line:sub(1, 1)
        if ch == '+' or ch == '-' then
          pcall(api.nvim_buf_set_extmark, preview_bufnr, ns, hunk.start_line + j - 1, 0, {
            end_col = 1,
            hl_group = ch == '+' and '@diff.plus' or '@diff.minus',
            priority = opts.highlights.priorities.syntax,
          })
        end
      end
    end

    dbg('gitsigns blame: highlighted %d hunks in popup buf %d', #hunks, preview_bufnr)
  end)
  if not ok then
    dbg('gitsigns blame error: %s', err)
  end
end

---@return boolean
function M.setup()
  if patched then
    return true
  end

  local pop_ok, Popup = pcall(require, 'gitsigns.popup')
  if not pop_ok or not Popup then
    return false
  end

  Popup.create = (function(orig)
    return function(...)
      local winid, bufnr = orig(...)
      on_preview(winid, bufnr)
      return winid, bufnr
    end
  end)(Popup.create)

  Popup.update = (function(orig)
    return function(winid, bufnr, ...)
      orig(winid, bufnr, ...)
      on_preview(winid, bufnr)
    end
  end)(Popup.update)

  patched = true
  dbg('gitsigns popup patched')
  return true
end

M._test = {
  parse_blame_hunks = M.parse_blame_hunks,
  on_preview = on_preview,
  ns = ns,
  gs_popup_ns = gs_popup_ns,
}

return M
