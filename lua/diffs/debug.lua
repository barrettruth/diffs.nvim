local M = {}

local ns = vim.api.nvim_create_namespace('diffs')

function M.dump()
  local bufnr = vim.api.nvim_get_current_buf()
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local by_line = {}
  for _, mark in ipairs(marks) do
    local id, row, col, details = mark[1], mark[2], mark[3], mark[4]
    local entry = {
      id = id,
      row = row,
      col = col,
      end_row = details.end_row,
      end_col = details.end_col,
      hl_group = details.hl_group,
      priority = details.priority,
      hl_eol = details.hl_eol,
      line_hl_group = details.line_hl_group,
      number_hl_group = details.number_hl_group,
      virt_text = details.virt_text,
    }
    local key = tostring(row)
    if not by_line[key] then
      by_line[key] = { text = lines[row + 1] or '', marks = {} }
    end
    table.insert(by_line[key].marks, entry)
  end

  local all_ns_marks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
  local non_diffs = {}
  for _, mark in ipairs(all_ns_marks) do
    local details = mark[4]
    if details.ns_id ~= ns then
      table.insert(non_diffs, {
        ns_id = details.ns_id,
        row = mark[2],
        col = mark[3],
        end_row = details.end_row,
        end_col = details.end_col,
        hl_group = details.hl_group,
        priority = details.priority,
      })
    end
  end

  local result = {
    bufnr = bufnr,
    buf_name = vim.api.nvim_buf_get_name(bufnr),
    ns_id = ns,
    total_diffs_marks = #marks,
    total_all_marks = #all_ns_marks,
    non_diffs_marks = non_diffs,
    lines = by_line,
  }

  local state_dir = vim.fn.stdpath('state')
  local path = state_dir .. '/diffs_debug.json'
  local f = io.open(path, 'w')
  if f then
    f:write(vim.json.encode(result))
    f:close()
    vim.notify('[diffs.nvim] debug dump: ' .. path, vim.log.levels.INFO)
  end
end

return M
