require('spec.helpers')
local diffs = require('diffs')

describe('diffs', function()
  describe('setup', function()
    it('accepts empty config', function()
      assert.has_no.errors(function()
        diffs.setup({})
      end)
    end)

    it('accepts nil config', function()
      assert.has_no.errors(function()
        diffs.setup()
      end)
    end)

    it('accepts full config', function()
      assert.has_no.errors(function()
        diffs.setup({
          enabled = false,
          debug = true,
          debounce_ms = 100,
          hide_prefix = false,
          treesitter = {
            enabled = true,
            max_lines = 1000,
          },
          vim = {
            enabled = false,
            max_lines = 200,
          },
          highlights = {
            background = true,
            gutter = true,
          },
        })
      end)
    end)

    it('accepts partial config', function()
      assert.has_no.errors(function()
        diffs.setup({
          debounce_ms = 25,
        })
      end)
    end)
  end)

  describe('attach', function()
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

    before_each(function()
      diffs.setup({ enabled = true })
    end)

    it('does not error on empty buffer', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        diffs.attach(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('does not error on buffer with content', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      assert.has_no.errors(function()
        diffs.attach(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('is idempotent', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        diffs.attach(bufnr)
        diffs.attach(bufnr)
        diffs.attach(bufnr)
      end)
      delete_buffer(bufnr)
    end)
  end)

  describe('refresh', function()
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

    before_each(function()
      diffs.setup({ enabled = true })
    end)

    it('does not error on unattached buffer', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        diffs.refresh(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('does not error on attached buffer', function()
      local bufnr = create_buffer({})
      diffs.attach(bufnr)
      assert.has_no.errors(function()
        diffs.refresh(bufnr)
      end)
      delete_buffer(bufnr)
    end)
  end)

  describe('config options', function()
    it('enabled=false prevents highlighting', function()
      diffs.setup({ enabled = false })
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      diffs.attach(bufnr)

      local ns = vim.api.nvim_create_namespace('diffs')
      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
      assert.are.equal(0, #extmarks)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
