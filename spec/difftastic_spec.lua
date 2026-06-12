require('spec.helpers')

local config = require('diffs.config')
local difftastic = require('diffs.difftastic')
local runtime = require('diffs.runtime')

describe('diffs.difftastic', function()
  describe('config', function()
    it('accepts integrations.difftastic = true', function()
      assert.has_no.errors(function()
        config.new({ integrations = { difftastic = true } })
      end)
    end)

    it('accepts a table with args', function()
      assert.has_no.errors(function()
        config.new({ integrations = { difftastic = { args = { '--ignore-comments' } } } })
      end)
    end)

    it('rejects a non-boolean/table value', function()
      assert.has.errors(function()
        config.new({ integrations = { difftastic = 42 } })
      end)
    end)

    it('rejects args that is not a list', function()
      assert.has.errors(function()
        config.new({ integrations = { difftastic = { args = 'nope' } } })
      end)
    end)

    it('rejects args with non-string elements', function()
      assert.has.errors(function()
        config.new({ integrations = { difftastic = { args = { 123, '--flag' } } } })
      end)
    end)

    it('defaults to disabled when unset', function()
      local cfg = config.new({})
      assert.is_nil(cfg.integrations.difftastic)
    end)
  end)

  describe('resolve', function()
    local original
    before_each(function()
      original = runtime.get_difftastic_config
    end)
    after_each(function()
      runtime.get_difftastic_config = original
    end)

    it('is disabled for nil/false', function()
      runtime.get_difftastic_config = function()
        return nil
      end
      assert.is_false(difftastic.resolve().enabled)
      runtime.get_difftastic_config = function()
        return false
      end
      assert.is_false(difftastic.resolve().enabled)
    end)

    it('is enabled with empty args for true', function()
      runtime.get_difftastic_config = function()
        return true
      end
      local cfg = difftastic.resolve()
      assert.is_true(cfg.enabled)
      assert.same({}, cfg.args)
    end)

    it('forwards args from a table', function()
      runtime.get_difftastic_config = function()
        return { args = { '--ignore-comments' } }
      end
      assert.same({ '--ignore-comments' }, difftastic.resolve().args)
    end)
  end)

  describe('span_maps', function()
    it('keys changes by line_number and is order-independent', function()
      local json = {
        chunks = {
          {
            { lhs = vim.NIL, rhs = { line_number = 5, changes = { { start = 2, ['end'] = 6 } } } },
            { lhs = { line_number = 1, changes = { { start = 0, ['end'] = 3 } } }, rhs = vim.NIL },
          },
        },
      }
      local lhs, rhs = difftastic.span_maps(json)
      assert.same({ { col_start = 0, col_end = 3 } }, lhs[1])
      assert.same({ { col_start = 2, col_end = 6 } }, rhs[5])
    end)

    it('drops empty/zero-width spans and vim.NIL sides', function()
      local json = {
        chunks = {
          {
            { lhs = { line_number = 0, changes = { { start = 1, ['end'] = 1 } } }, rhs = vim.NIL },
          },
        },
      }
      local lhs = difftastic.span_maps(json)
      assert.same({}, lhs[0])
    end)
  end)

  describe('has_changes', function()
    it('is true only when a side has spans', function()
      assert.is_false(difftastic.has_changes({}, {}))
      assert.is_true(difftastic.has_changes({ [1] = { { col_start = 0, col_end = 1 } } }, {}))
    end)
  end)

  describe('build_alignment', function()
    -- old = {a,b,c}; new = {a,C}: a unchanged, b deleted, c rewritten to C
    local json = {
      language = 'Lua',
      status = 'changed',
      aligned_lines = { { 0, 0 }, { 1, vim.NIL }, { 2, 1 } },
      chunks = {
        {
          { lhs = { line_number = 1, changes = { { start = 0, ['end'] = 1 } } }, rhs = vim.NIL },
          {
            lhs = { line_number = 2, changes = { { start = 0, ['end'] = 1 } } },
            rhs = { line_number = 1, changes = { { start = 0, ['end'] = 1 } } },
          },
        },
      },
    }

    it('produces aligned rows with structural kinds', function()
      local a = difftastic.build_alignment(json, { 'a', 'b', 'c' }, { 'a', 'C' })
      assert.same({ 'a', 'b', 'c' }, a.left_lines)
      assert.same({ 'a', '', 'C' }, a.right_lines)
      assert.are.equal('context', a.left_rows[1].kind)
      assert.are.equal('delete', a.left_rows[2].kind)
      assert.are.equal('filler', a.right_rows[2].kind)
      assert.are.equal('delete', a.left_rows[3].kind)
      assert.are.equal('add', a.right_rows[3].kind)
    end)

    it('reports changed and anchors at the first changed run', function()
      local a = difftastic.build_alignment(json, { 'a', 'b', 'c' }, { 'a', 'C' })
      assert.is_true(a.changed)
      assert.same({ 2 }, a.anchors)
    end)

    it('carries per-row intra spans', function()
      local a = difftastic.build_alignment(json, { 'a', 'b', 'c' }, { 'a', 'C' })
      assert.same({ { col_start = 0, col_end = 1 } }, a.left_intra[3])
      assert.same({ { col_start = 0, col_end = 1 } }, a.right_intra[3])
      assert.is_nil(a.right_intra[1])
    end)

    it('reports not changed for a structurally identical alignment', function()
      local a = difftastic.build_alignment({
        aligned_lines = { { 0, 0 }, { 1, 1 } },
        chunks = {},
      }, { 'a', 'b' }, { 'a', 'b' })
      assert.is_false(a.changed)
      assert.same({}, a.anchors)
    end)
  end)

  describe('integration (difft-gated)', function()
    if vim.fn.executable('difft') ~= 1 then
      return
    end

    local original
    before_each(function()
      original = runtime.get_difftastic_config
      runtime.get_difftastic_config = function()
        return true
      end
    end)
    after_each(function()
      runtime.get_difftastic_config = original
    end)

    it('aligns a rename via real difft', function()
      local old_lines = { 'local function clamp(value, low, high)', '  return low', 'end' }
      local new_lines =
        { 'local function clamp(value, low, high)', '  return math.max(low, value)', 'end' }
      local a = difftastic.align(old_lines, new_lines, 'rate.lua')
      assert.is_truthy(a)
      assert.is_true(a.changed)
      assert.are.equal(#a.left_lines, #a.right_lines)
    end)

    it('reports not changed for a reindentation-only change', function()
      local old_lines = { 'local function f()', 'return 1', 'end' }
      local new_lines = { 'local function f()', '    return 1', 'end' }
      local a = difftastic.align(old_lines, new_lines, 'x.lua')
      assert.is_truthy(a)
      assert.is_false(a.changed)
    end)

    it('falls back cleanly on all-added and all-removed files', function()
      assert.is_nil(difftastic.align({}, { 'local x = 1', 'return x' }, 'x.lua'))
      assert.is_nil(difftastic.align({ 'local x = 1', 'return x' }, {}, 'x.lua'))
    end)

    it('keeps byte offsets aligned with tabs and multibyte chars', function()
      local _, rhs = difftastic.span_maps_for_content(
        { '\tlocal café_count = 1' },
        { '\tlocal café_count = 2' },
        'x.lua'
      )
      assert.is_truthy(rhs and rhs[0])
      local line = '\tlocal café_count = 2'
      local span = rhs[0][1]
      assert.are.equal('2', line:sub(span.col_start + 1, span.col_end))
    end)
  end)
end)
