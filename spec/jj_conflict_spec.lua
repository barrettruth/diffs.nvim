local conflict = require('diffs.conflict')

local function default_config(overrides)
  local cfg = {
    enabled = true,
    disable_diagnostics = false,
    show_virtual_text = false,
    show_actions = false,
    keymaps = false,
  }
  if overrides then
    cfg = vim.tbl_deep_extend('force', cfg, overrides)
  end
  return cfg
end

local function create_file_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  return bufnr
end

local function snapshot_lines()
  return {
    'line1',
    '<<<<<<< conflict 1 of 1',
    '+++++++ tzmtwuuv 321864a5 "sidea" (rebase destination)',
    'AAA',
    '------- sozvolrq 24563c2b "base" (parents of rebased revision)',
    'line2',
    '+++++++ vooloppp 8bb449c1 "sideb" (rebased revision)',
    'BBB',
    '>>>>>>> conflict 1 of 1 ends',
    'line3',
  }
end

local function diff_lines()
  return {
    'line1',
    '<<<<<<< conflict 1 of 1',
    '%%%%%%% diff from: sozvolrq 24563c2b "base" (parents of rebased revision)',
    '\\\\\\\\\\\\\\        to: tzmtwuuv 321864a5 "sidea" (rebase destination)',
    '-line2',
    '+AAA',
    '+++++++ vooloppp 8bb449c1 "sideb" (rebased revision)',
    'BBB',
    '>>>>>>> conflict 1 of 1 ends',
    'line3',
  }
end

local function three_sided_lines()
  return {
    'line1',
    '<<<<<<< conflict 1 of 1',
    '+++++++ sideA',
    'AAA',
    '------- base',
    'line2',
    '+++++++ sideB',
    'BBB',
    '------- base',
    'line2',
    '+++++++ sideC',
    'CCC',
    '>>>>>>> conflict 1 of 1 ends',
    'line3',
  }
end

describe('jj conflict markers', function()
  describe('snapshot style', function()
    it('parses a two sided conflict', function()
      local regions = conflict.parse(snapshot_lines())
      assert.are.equal(1, #regions)
      local region = regions[1]
      assert.are.equal(1, region.marker_open)
      assert.are.equal(2, region.marker_ours)
      assert.are.equal(3, region.ours_start)
      assert.are.equal(4, region.ours_end)
      assert.are.equal(4, region.marker_base)
      assert.are.equal(5, region.base_start)
      assert.are.equal(6, region.base_end)
      assert.are.equal(6, region.marker_sep)
      assert.are.equal(7, region.theirs_start)
      assert.are.equal(8, region.theirs_end)
      assert.are.equal(8, region.marker_theirs)
    end)

    it('resolves to the first side', function()
      local bufnr = create_file_buffer(snapshot_lines())
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      conflict.resolve_ours(bufnr, default_config())
      assert.are.same({ 'line1', 'AAA', 'line3' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('resolves to the last side', function()
      local bufnr = create_file_buffer(snapshot_lines())
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      conflict.resolve_theirs(bufnr, default_config())
      assert.are.same({ 'line1', 'BBB', 'line3' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('removes the opening marker when resolving', function()
      local bufnr = create_file_buffer(snapshot_lines())
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      conflict.resolve_none(bufnr, default_config())
      assert.are.same({ 'line1', 'line3' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('highlights the opening marker', function()
      local bufnr = create_file_buffer(snapshot_lines())
      conflict.attach(bufnr, default_config())
      local rows = {}
      for _, mark in
        ipairs(
          vim.api.nvim_buf_get_extmarks(bufnr, conflict.get_namespace(), 0, -1, { details = true })
        )
      do
        if mark[4] and mark[4].hl_group == 'DiffsConflictMarker' then
          rows[mark[2]] = true
        end
      end
      assert.is_true(rows[1])
      assert.is_true(rows[2])
      assert.is_true(rows[4])
      assert.is_true(rows[6])
      assert.is_true(rows[8])
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('unsupported styles', function()
    it('does not parse diff style', function()
      assert.are.equal(0, #conflict.parse(diff_lines()))
    end)

    it('does not parse conflicts with more than two sides', function()
      assert.are.equal(0, #conflict.parse(three_sided_lines()))
    end)

    it('does not attach when nothing parses', function()
      local bufnr = create_file_buffer(diff_lines())
      conflict.attach(bufnr, default_config({ keymaps = { ours = 'gto' } }))
      assert.are.equal(
        0,
        #vim.api.nvim_buf_get_extmarks(bufnr, conflict.get_namespace(), 0, -1, {})
      )
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('git style regression', function()
    it('still parses without an opening marker field', function()
      local regions = conflict.parse({
        '<<<<<<< tzmtwuuv 321864a5 "sidea" (rebase destination)',
        'AAA',
        '||||||| sozvolrq 24563c2b "base" (parents of rebased revision)',
        'line2',
        '=======',
        'BBB',
        '>>>>>>> vooloppp 8bb449c1 "sideb" (rebased revision)',
      })
      assert.are.equal(1, #regions)
      assert.is_nil(regions[1].marker_open)
      assert.are.equal(0, regions[1].marker_ours)
      assert.are.equal(6, regions[1].marker_theirs)
    end)
  end)
end)
