require('spec.helpers')
local fugitive_ts = require('fugitive-ts')

describe('fugitive-ts', function()
  describe('setup', function()
    it('accepts empty config', function()
      assert.has_no.errors(function()
        fugitive_ts.setup({})
      end)
    end)

    it('accepts nil config', function()
      assert.has_no.errors(function()
        fugitive_ts.setup()
      end)
    end)

    it('accepts full config', function()
      assert.has_no.errors(function()
        fugitive_ts.setup({
          enabled = false,
          debug = true,
          languages = { ['.envrc'] = 'bash' },
          disabled_languages = { 'markdown' },
          debounce_ms = 100,
          max_lines_per_hunk = 1000,
          conceal_prefixes = false,
          highlights = {
            treesitter = true,
            background = true,
            gutter = true,
            vim = false,
          },
        })
      end)
    end)

    it('accepts partial config', function()
      assert.has_no.errors(function()
        fugitive_ts.setup({
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
      fugitive_ts.setup({ enabled = true })
    end)

    it('does not error on empty buffer', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        fugitive_ts.attach(bufnr)
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
        fugitive_ts.attach(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('is idempotent', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        fugitive_ts.attach(bufnr)
        fugitive_ts.attach(bufnr)
        fugitive_ts.attach(bufnr)
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
      fugitive_ts.setup({ enabled = true })
    end)

    it('does not error on unattached buffer', function()
      local bufnr = create_buffer({})
      assert.has_no.errors(function()
        fugitive_ts.refresh(bufnr)
      end)
      delete_buffer(bufnr)
    end)

    it('does not error on attached buffer', function()
      local bufnr = create_buffer({})
      fugitive_ts.attach(bufnr)
      assert.has_no.errors(function()
        fugitive_ts.refresh(bufnr)
      end)
      delete_buffer(bufnr)
    end)
  end)

  describe('config options', function()
    it('enabled=false prevents highlighting', function()
      fugitive_ts.setup({ enabled = false })
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'M test.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      fugitive_ts.attach(bufnr)

      local ns = vim.api.nvim_create_namespace('fugitive_ts')
      local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
      assert.are.equal(0, #extmarks)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
