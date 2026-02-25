require('spec.helpers')

vim.g.diffs = { neogit = true }

local diffs = require('diffs')
local parser = require('diffs.parser')

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

describe('neogit_integration', function()
  describe('neogit_disable_hunk_highlight', function()
    it('sets neogit_disable_hunk_highlight on NeogitStatus buffer after attach', function()
      local bufnr = create_buffer({
        'modified   test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      vim.api.nvim_set_option_value('filetype', 'NeogitStatus', { buf = bufnr })
      diffs.attach(bufnr)

      assert.is_true(vim.b[bufnr].neogit_disable_hunk_highlight)

      delete_buffer(bufnr)
    end)

    it('does not set neogit_disable_hunk_highlight on non-Neogit buffer', function()
      local bufnr = create_buffer({})
      vim.api.nvim_set_option_value('filetype', 'git', { buf = bufnr })
      diffs.attach(bufnr)

      assert.is_not_true(vim.b[bufnr].neogit_disable_hunk_highlight)

      delete_buffer(bufnr)
    end)
  end)

  describe('NeogitStatus buffer attach', function()
    it('populates hunk_cache for NeogitStatus buffer with diff content', function()
      local bufnr = create_buffer({
        'modified   hello.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
        ' return M',
      })
      vim.api.nvim_set_option_value('filetype', 'NeogitStatus', { buf = bufnr })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.is_table(entry.hunks)
      assert.are.equal(1, #entry.hunks)
      assert.are.equal('hello.lua', entry.hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('populates hunk_cache for NeogitDiffView buffer', function()
      local bufnr = create_buffer({
        'new file   newmod.lua',
        '@@ -0,0 +1,2 @@',
        '+local M = {}',
        '+return M',
      })
      vim.api.nvim_set_option_value('filetype', 'NeogitDiffView', { buf = bufnr })
      diffs.attach(bufnr)
      local entry = diffs._test.hunk_cache[bufnr]
      assert.is_not_nil(entry)
      assert.is_table(entry.hunks)
      assert.are.equal(1, #entry.hunks)
      delete_buffer(bufnr)
    end)
  end)

  describe('parser neogit patterns', function()
    it('detects renamed prefix via parser', function()
      local bufnr = create_buffer({
        'renamed   old.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
        ' return M',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.equal('old.lua', hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('detects copied prefix via parser', function()
      local bufnr = create_buffer({
        'copied   orig.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
        ' return M',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.equal('orig.lua', hunks[1].filename)
      delete_buffer(bufnr)
    end)

    it('detects deleted prefix via parser', function()
      local bufnr = create_buffer({
        'deleted   gone.lua',
        '@@ -1,2 +0,0 @@',
        '-local M = {}',
        '-return M',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.equal(1, #hunks)
      assert.are.equal('gone.lua', hunks[1].filename)
      delete_buffer(bufnr)
    end)
  end)
end)
