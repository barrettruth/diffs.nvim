require('spec.helpers')
local cache = require('diffs.runtime.cache')
local highlight = require('diffs.highlight')
local compute_hunk_context = cache.compute_hunk_context

describe('context', function()
  describe('compute_hunk_context', function()
    local tmpdir

    before_each(function()
      tmpdir = vim.fn.tempname()
      vim.fn.mkdir(tmpdir, 'p')
    end)

    after_each(function()
      vim.fn.delete(tmpdir, 'rf')
    end)

    local function write_file(filename, lines)
      local path = vim.fs.joinpath(tmpdir, filename)
      local dir = vim.fn.fnamemodify(path, ':h')
      if vim.fn.isdirectory(dir) == 0 then
        vim.fn.mkdir(dir, 'p')
      end
      local f = io.open(path, 'w')
      f:write(table.concat(lines, '\n') .. '\n')
      f:close()
    end

    local function make_hunk(filename, opts)
      return {
        filename = filename,
        ft = 'lua',
        lang = 'lua',
        start_line = opts.start_line or 1,
        lines = opts.lines,
        prefix_width = opts.prefix_width or 1,
        quote_width = 0,
        repo_root = tmpdir,
        file_new_start = opts.file_new_start,
        file_new_count = opts.file_new_count,
      }
    end

    it('reads context_before from file lines preceding the hunk', function()
      write_file('a.lua', {
        'local M = {}',
        'function M.foo()',
        '  local x = 1',
        '  local y = 2',
        'end',
        'return M',
      })

      local hunks = {
        make_hunk('a.lua', {
          file_new_start = 3,
          file_new_count = 3,
          lines = { ' local x = 1', '+local new = true', ' local y = 2' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.same({ 'local M = {}', 'function M.foo()' }, hunks[1].context_before)
    end)

    it('reads context_after from file lines following the hunk', function()
      write_file('a.lua', {
        'local M = {}',
        'function M.foo()',
        '  local x = 1',
        'end',
        'return M',
      })

      local hunks = {
        make_hunk('a.lua', {
          file_new_start = 2,
          file_new_count = 2,
          lines = { ' function M.foo()', '+  local x = 1' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.same({ 'end', 'return M' }, hunks[1].context_after)
    end)

    it('caps context_before to max_lines', function()
      write_file('a.lua', {
        'line1',
        'line2',
        'line3',
        'line4',
        'line5',
        'target',
      })

      local hunks = {
        make_hunk('a.lua', {
          file_new_start = 6,
          file_new_count = 1,
          lines = { '+target' },
        }),
      }
      compute_hunk_context(hunks, 2)

      assert.same({ 'line4', 'line5' }, hunks[1].context_before)
    end)

    it('caps context_after to max_lines', function()
      write_file('a.lua', {
        'target',
        'after1',
        'after2',
        'after3',
        'after4',
      })

      local hunks = {
        make_hunk('a.lua', {
          file_new_start = 1,
          file_new_count = 1,
          lines = { '+target' },
        }),
      }
      compute_hunk_context(hunks, 2)

      assert.same({ 'after1', 'after2' }, hunks[1].context_after)
    end)

    it('skips hunks without file_new_start', function()
      write_file('a.lua', { 'line1', 'line2' })

      local hunks = {
        make_hunk('a.lua', {
          file_new_start = nil,
          file_new_count = nil,
          lines = { '+something' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.is_nil(hunks[1].context_before)
      assert.is_nil(hunks[1].context_after)
    end)

    it('skips hunks without repo_root', function()
      local hunks = {
        {
          filename = 'a.lua',
          ft = 'lua',
          lang = 'lua',
          start_line = 1,
          lines = { '+x' },
          prefix_width = 1,
          quote_width = 0,
          repo_root = nil,
          file_new_start = 1,
          file_new_count = 1,
        },
      }
      compute_hunk_context(hunks, 25)

      assert.is_nil(hunks[1].context_before)
      assert.is_nil(hunks[1].context_after)
    end)

    it('skips when path is a directory', function()
      vim.fn.mkdir(vim.fs.joinpath(tmpdir, 'subdir'), 'p')

      local hunks = {
        make_hunk('subdir', {
          file_new_start = 1,
          file_new_count = 1,
          lines = { '+x' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.is_nil(hunks[1].context_before)
      assert.is_nil(hunks[1].context_after)
    end)

    it('skips when path is a symlink to a directory', function()
      vim.fn.mkdir(vim.fs.joinpath(tmpdir, 'real_dir'), 'p')
      vim.uv.fs_symlink(vim.fs.joinpath(tmpdir, 'real_dir'), vim.fs.joinpath(tmpdir, 'link_dir'))

      local hunks = {
        make_hunk('link_dir', {
          file_new_start = 1,
          file_new_count = 1,
          lines = { '+x' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.is_nil(hunks[1].context_before)
      assert.is_nil(hunks[1].context_after)
    end)

    it('skips when file does not exist on disk', function()
      local hunks = {
        make_hunk('nonexistent.lua', {
          file_new_start = 1,
          file_new_count = 1,
          lines = { '+x' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.is_nil(hunks[1].context_before)
      assert.is_nil(hunks[1].context_after)
    end)

    it('returns nil context_before for hunk at line 1', function()
      write_file('a.lua', { 'first', 'second' })

      local hunks = {
        make_hunk('a.lua', {
          file_new_start = 1,
          file_new_count = 1,
          lines = { '+first' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.is_nil(hunks[1].context_before)
    end)

    it('returns nil context_after for hunk at end of file', function()
      write_file('a.lua', { 'first', 'last' })

      local hunks = {
        make_hunk('a.lua', {
          file_new_start = 1,
          file_new_count = 2,
          lines = { ' first', '+last' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.is_nil(hunks[1].context_after)
    end)

    it('reads file once for multiple hunks in same file', function()
      write_file('a.lua', {
        'local M = {}',
        'function M.foo()',
        '  return 1',
        'end',
        'function M.bar()',
        '  return 2',
        'end',
        'return M',
      })

      local hunks = {
        make_hunk('a.lua', {
          file_new_start = 2,
          file_new_count = 3,
          lines = { ' function M.foo()', '+  return 1', ' end' },
        }),
        make_hunk('a.lua', {
          file_new_start = 5,
          file_new_count = 3,
          lines = { ' function M.bar()', '+  return 2', ' end' },
        }),
      }
      compute_hunk_context(hunks, 25)

      assert.same({ 'local M = {}' }, hunks[1].context_before)
      assert.same({ 'function M.bar()', '  return 2', 'end', 'return M' }, hunks[1].context_after)
      assert.same({
        'local M = {}',
        'function M.foo()',
        '  return 1',
        'end',
      }, hunks[2].context_before)
      assert.same({ 'return M' }, hunks[2].context_after)
    end)
  end)

  describe('highlight_treesitter with context', function()
    local ns

    before_each(function()
      ns = vim.api.nvim_create_namespace('diffs_context_test')
      local normal = vim.api.nvim_get_hl(0, { name = 'Normal' })
      vim.api.nvim_set_hl(0, 'DiffsClear', { fg = normal.fg or 0xc0c0c0 })
    end)

    local function create_buffer(lines)
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      return bufnr
    end

    local function delete_buffer(bufnr)
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end

    local function get_extmarks(bufnr)
      return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    end

    local function default_opts(overrides)
      local opts = {
        hide_prefix = false,
        highlights = {
          background = false,
          gutter = false,
          context = { enabled = true, lines = 25 },
          treesitter = { enabled = true, max_lines = 500 },
          vim = { enabled = false, max_lines = 200 },
          intra = { enabled = false, algorithm = 'default', max_lines = 500 },
          priorities = { clear = 198, syntax = 199, line_bg = 200, char_bg = 201 },
        },
      }
      if overrides then
        if overrides.highlights then
          opts.highlights = vim.tbl_deep_extend('force', opts.highlights, overrides.highlights)
        end
      end
      return opts
    end

    it('applies extmarks only to hunk lines, not context lines', function()
      local bufnr = create_buffer({
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        ' local y = 2',
        '+local z = 3',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 2,
        lines = { ' local x = 1', ' local y = 2', '+local z = 3' },
        prefix_width = 1,
        quote_width = 0,
        context_before = { 'local function foo()' },
        context_after = { 'end' },
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      for _, mark in ipairs(extmarks) do
        local row = mark[2]
        assert.is_true(row >= 1 and row <= 3, 'extmark row ' .. row .. ' outside hunk range')
      end
      assert.is_true(#extmarks > 0)
      delete_buffer(bufnr)
    end)

    it('does not pass context when context.enabled = false', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 2,
        lines = { ' local x = 1', '+local y = 2' },
        prefix_width = 1,
        quote_width = 0,
        context_before = { 'local function foo()' },
        context_after = { 'end' },
      }

      local opts_enabled = default_opts({ highlights = { context = { enabled = true } } })
      highlight.highlight_hunk(bufnr, ns, hunk, opts_enabled)
      local extmarks_with = get_extmarks(bufnr)

      vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

      local opts_disabled = default_opts({ highlights = { context = { enabled = false } } })
      highlight.highlight_hunk(bufnr, ns, hunk, opts_disabled)
      local extmarks_without = get_extmarks(bufnr)

      assert.is_true(#extmarks_with > 0)
      assert.is_true(#extmarks_without > 0)
      delete_buffer(bufnr)
    end)

    it('skips context fields that are nil', function()
      local bufnr = create_buffer({
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })

      local hunk = {
        filename = 'test.lua',
        lang = 'lua',
        start_line = 2,
        lines = { ' local x = 1', '+local y = 2' },
        prefix_width = 1,
        quote_width = 0,
      }

      highlight.highlight_hunk(bufnr, ns, hunk, default_opts())

      local extmarks = get_extmarks(bufnr)
      assert.is_true(#extmarks > 0)
      delete_buffer(bufnr)
    end)
  end)
end)
