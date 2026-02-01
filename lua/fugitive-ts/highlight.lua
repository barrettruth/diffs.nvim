local M = {}

---@param bufnr integer
---@param ns integer
---@param hunk fugitive-ts.Hunk
function M.highlight_hunk(bufnr, ns, hunk)
  local lang = hunk.lang
  if not lang then
    return
  end

  ---@type string[]
  local code_lines = {}
  for _, line in ipairs(hunk.lines) do
    table.insert(code_lines, line:sub(2))
  end

  local code = table.concat(code_lines, '\n')
  if code == '' then
    return
  end

  local ok, parser_obj = pcall(vim.treesitter.get_string_parser, code, lang)
  if not ok or not parser_obj then
    return
  end

  local trees = parser_obj:parse()
  if not trees or #trees == 0 then
    return
  end

  local query = vim.treesitter.query.get(lang, 'highlights')
  if not query then
    return
  end

  for id, node, _ in query:iter_captures(trees[1]:root(), code) do
    local capture_name = '@' .. query.captures[id]
    local sr, sc, er, ec = node:range()

    local buf_sr = hunk.start_line + sr
    local buf_er = hunk.start_line + er
    local buf_sc = sc + 1
    local buf_ec = ec + 1

    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, buf_sr, buf_sc, {
      end_row = buf_er,
      end_col = buf_ec,
      hl_group = capture_name,
      priority = 200,
    })
  end
end

return M
