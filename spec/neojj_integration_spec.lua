require('spec.helpers')

vim.g.diffs = { integrations = { neojj = true } }

local config = require('diffs.config')
local parser = require('diffs.parser')
local runtime = require('diffs.runtime')

local function create_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  return bufnr
end

local function delete_buffer(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
end

describe('neojj_integration', function()
  describe('neojj_disable_hunk_highlight', function()
    it('sets neojj_disable_hunk_highlight on NeojjStatus buffer after attach', function()
      local bufnr = create_buffer({
        'modified   test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      vim.api.nvim_set_option_value('filetype', 'NeojjStatus', { buf = bufnr })
      runtime.attach(bufnr)

      assert.is_true(vim.b[bufnr].neojj_disable_hunk_highlight)

      delete_buffer(bufnr)
    end)

    it('does not set neojj_disable_hunk_highlight on non-Neojj buffer', function()
      local bufnr = create_buffer({})
      vim.api.nvim_set_option_value('filetype', 'git', { buf = bufnr })
      runtime.attach(bufnr)

      assert.is_not_true(vim.b[bufnr].neojj_disable_hunk_highlight)

      delete_buffer(bufnr)
    end)
  end)

  describe('NeojjStatus buffer attach', function()
    it('populates hunk_cache for NeojjStatus buffer with diff content', function()
      local bufnr = create_buffer({
        'modified   hello.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
        ' return M',
      })
      vim.api.nvim_set_option_value('filetype', 'NeojjStatus', { buf = bufnr })
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.is_table(entry.hunks)
      assert.are.equal(1, #entry.hunks)
      assert.are.equal('hello.lua', entry.hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('populates hunk_cache for NeojjDiffView buffer', function()
      local bufnr = create_buffer({
        'new file   newmod.lua',
        '@@ -0,0 +1,2 @@',
        '+local M = {}',
        '+return M',
      })
      vim.api.nvim_set_option_value('filetype', 'NeojjDiffView', { buf = bufnr })
      runtime.attach(bufnr)
      local entry = runtime._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.is_table(entry.hunks)
      assert.are.equal(1, #entry.hunks)
      delete_buffer(bufnr)
    end)
  end)

  describe('parser neojj patterns', function()
    it('detects added prefix via parser', function()
      local bufnr = create_buffer({
        'added   utils.py',
        '@@ -0,0 +1,2 @@',
        '+def hello():',
        '+    pass',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.equal('utils.py', hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('detects updated prefix via parser', function()
      local bufnr = create_buffer({
        'updated   config.toml',
        '@@ -1,2 +1,3 @@',
        ' [section]',
        '+key = "val"',
        ' other = 1',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.equal('config.toml', hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('detects changed prefix via parser', function()
      local bufnr = create_buffer({
        'changed   main.rs',
        '@@ -1,1 +1,2 @@',
        ' fn main() {}',
        '+fn helper() {}',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.equal('main.rs', hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('detects unmerged prefix via parser', function()
      local bufnr = create_buffer({
        'unmerged   conflict.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.equal('conflict.lua', hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('parses multi-file neojj buffer with modified and added', function()
      local bufnr = create_buffer({
        'modified   test.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
        ' return M',
        'added   utils.py',
        '@@ -0,0 +1,2 @@',
        '+def hello():',
        '+    pass',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.equal(2, #hunks)
      assert.are.equal('test.lua', hunks[1].filename)
      assert.are.equal('utils.py', hunks[2].filename)
      delete_buffer(bufnr)
    end)
  end)

  describe('compute_filetypes', function()
    it('includes Neojj filetypes when neojj integration is enabled', function()
      local fts = config.compute_filetypes({ integrations = { neojj = true } })
      assert.is_true(vim.tbl_contains(fts, 'NeojjStatus'))
      assert.is_true(vim.tbl_contains(fts, 'NeojjCommitView'))
      assert.is_true(vim.tbl_contains(fts, 'NeojjDiffView'))
    end)

    it('excludes Neojj filetypes when neojj integration is disabled', function()
      local fts = config.compute_filetypes({ integrations = { neojj = false } })
      assert.is_false(vim.tbl_contains(fts, 'NeojjStatus'))
      assert.is_false(vim.tbl_contains(fts, 'NeojjCommitView'))
      assert.is_false(vim.tbl_contains(fts, 'NeojjDiffView'))
    end)
  end)
end)
