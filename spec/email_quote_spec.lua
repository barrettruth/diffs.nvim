require('spec.helpers')
local parser = require('diffs.parser')
local highlight = require('diffs.highlight')

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

local function get_extmarks(bufnr, ns)
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

local function highlight_opts()
  return {
    hide_prefix = false,
    highlights = {
      background = true,
      gutter = false,
      context = { enabled = false, lines = 0 },
      treesitter = { enabled = true, max_lines = 500 },
      vim = { enabled = false, max_lines = 200 },
      intra = { enabled = false, algorithm = 'default', max_lines = 500 },
      priorities = { clear = 198, syntax = 199, line_bg = 200, char_bg = 201 },
    },
  }
end

describe('parser email-quoted diffs', function()

  it('parses a fully email-quoted unified diff', function()
    local bufnr = create_buffer({
      '> diff --git a/foo.py b/foo.py',
      '> index abc1234..def5678 100644',
      '> --- a/foo.py',
      '> +++ b/foo.py',
      '> @@ -0,0 +1,3 @@',
      '> +from typing import Annotated, final',
      '> +',
      '> +class Foo:',
    })
    local hunks = parser.parse_buffer(bufnr)

    assert.are.equal(1, #hunks)
    assert.are.equal('foo.py', hunks[1].filename)
    assert.are.equal(3, #hunks[1].lines)
    assert.are.equal('+from typing import Annotated, final', hunks[1].lines[1])
    assert.are.equal(2, hunks[1].quote_width)
    delete_buffer(bufnr)
  end)

  it('parses a quoted diff embedded in an email reply', function()
    local bufnr = create_buffer({
      'Looks good, one nit:',
      '',
      '> diff --git a/foo.py b/foo.py',
      '> @@ -0,0 +1,3 @@',
      '> +from typing import Annotated, final',
      '> +',
      '> +class Foo:',
      '',
      'Maybe rename Foo to Bar?',
    })
    local hunks = parser.parse_buffer(bufnr)

    assert.are.equal(1, #hunks)
    assert.are.equal('foo.py', hunks[1].filename)
    assert.are.equal(3, #hunks[1].lines)
    assert.are.equal(2, hunks[1].quote_width)
    delete_buffer(bufnr)
  end)

  it('sets quote_width = 0 on normal (unquoted) diffs', function()
    local bufnr = create_buffer({
      'diff --git a/bar.lua b/bar.lua',
      '@@ -1,2 +1,2 @@',
      '-old_line',
      '+new_line',
    })
    local hunks = parser.parse_buffer(bufnr)

    assert.are.equal(1, #hunks)
    assert.are.equal(0, hunks[1].quote_width)
    delete_buffer(bufnr)
  end)

  it('treats bare > lines as empty quoted lines', function()
    local bufnr = create_buffer({
      '> diff --git a/foo.py b/foo.py',
      '> @@ -1,3 +1,3 @@',
      '> -old',
      '>',
      '> +new',
    })
    local hunks = parser.parse_buffer(bufnr)

    assert.are.equal(1, #hunks)
    assert.are.equal(3, #hunks[1].lines)
    assert.are.equal('-old', hunks[1].lines[1])
    assert.are.equal(' ', hunks[1].lines[2])
    assert.are.equal('+new', hunks[1].lines[3])
    delete_buffer(bufnr)
  end)

  it('adjusts header_context_col for quote width', function()
    local bufnr = create_buffer({
      '> diff --git a/foo.py b/foo.py',
      '> @@ -1,2 +1,2 @@ def hello():',
      '> -old',
      '> +new',
    })
    local hunks = parser.parse_buffer(bufnr)

    assert.are.equal(1, #hunks)
    assert.are.equal('def hello():', hunks[1].header_context)
    assert.are.equal(#'@@ -1,2 +1,2 @@ ' + 2, hunks[1].header_context_col)
    delete_buffer(bufnr)
  end)

  it('handles deeply nested quotes', function()
    local bufnr = create_buffer({
      '>> diff --git a/foo.py b/foo.py',
      '>> @@ -0,0 +1,2 @@',
      '>> +line1',
      '>> +line2',
    })
    local hunks = parser.parse_buffer(bufnr)

    assert.are.equal(1, #hunks)
    assert.are.equal(3, hunks[1].quote_width)
    assert.are.equal('+line1', hunks[1].lines[1])
    delete_buffer(bufnr)
  end)
end)

describe('email-quoted header highlight suppression', function()
  before_each(function()
    vim.api.nvim_set_hl(0, 'DiffsClear', { fg = 0xc0c0c0, bg = 0x1e1e2e })
    vim.api.nvim_set_hl(0, 'DiffsAdd', { bg = 0x2e4a3a })
    vim.api.nvim_set_hl(0, 'DiffsDelete', { bg = 0x4a2e3a })
  end)

  it('applies DiffsClear to header lines when quote_width > 0', function()
    local bufnr = create_buffer({
      '> diff --git a/foo.py b/foo.py',
      '> index abc1234..def5678 100644',
      '> --- a/foo.py',
      '> +++ b/foo.py',
      '> @@ -0,0 +1,2 @@',
      '> +line1',
      '> +line2',
    })
    local hunks = parser.parse_buffer(bufnr)
    assert.are.equal(1, #hunks)

    local ns = vim.api.nvim_create_namespace('diffs_email_clear_test')
    highlight.highlight_hunk(bufnr, ns, hunks[1], highlight_opts())

    local extmarks = get_extmarks(bufnr, ns)
    local clear_lines = {}
    for _, mark in ipairs(extmarks) do
      local d = mark[4]
      if d and d.hl_group == 'DiffsClear' and mark[3] == 0 then
        clear_lines[mark[2]] = true
      end
    end
    assert.is_true(clear_lines[0] ~= nil, 'expected DiffsClear on diff --git line')
    assert.is_true(clear_lines[1] ~= nil, 'expected DiffsClear on index line')
    assert.is_true(clear_lines[2] ~= nil, 'expected DiffsClear on --- line')
    assert.is_true(clear_lines[3] ~= nil, 'expected DiffsClear on +++ line')
    delete_buffer(bufnr)
  end)

  it('applies DiffsClear and diff treesitter to @@ line when quote_width > 0', function()
    local bufnr = create_buffer({
      '> diff --git a/foo.py b/foo.py',
      '> @@ -0,0 +1,2 @@',
      '> +line1',
      '> +line2',
    })
    local hunks = parser.parse_buffer(bufnr)
    assert.are.equal(1, #hunks)

    local ns = vim.api.nvim_create_namespace('diffs_email_at_test')
    highlight.highlight_hunk(bufnr, ns, hunks[1], highlight_opts())

    local extmarks = get_extmarks(bufnr, ns)
    local has_at_clear = false
    local has_at_ts = false
    for _, mark in ipairs(extmarks) do
      local d = mark[4]
      if mark[2] == 1 and d then
        if d.hl_group == 'DiffsClear' and mark[3] == 0 then
          has_at_clear = true
        end
        if d.hl_group and d.hl_group:match('^@.*%.diff$') and d.priority == 199 then
          has_at_ts = true
        end
      end
    end
    assert.is_true(has_at_clear, 'expected DiffsClear on @@ line')
    assert.is_true(has_at_ts, 'expected diff treesitter capture on @@ line')
    delete_buffer(bufnr)
  end)

  it('does not apply DiffsClear to header lines when quote_width = 0', function()
    local bufnr = create_buffer({
      'diff --git a/foo.py b/foo.py',
      'index abc1234..def5678 100644',
      '--- a/foo.py',
      '+++ b/foo.py',
      '@@ -0,0 +1,2 @@',
      '+line1',
      '+line2',
    })
    local hunks = parser.parse_buffer(bufnr)
    assert.are.equal(1, #hunks)

    local ns = vim.api.nvim_create_namespace('diffs_email_noclear_test')
    highlight.highlight_hunk(bufnr, ns, hunks[1], highlight_opts())

    local extmarks = get_extmarks(bufnr, ns)
    for _, mark in ipairs(extmarks) do
      local d = mark[4]
      if d and d.hl_group == 'DiffsClear' and mark[3] == 0 and mark[2] < 5 then
        error('unexpected DiffsClear at col 0 on header line ' .. mark[2] .. ' with quote_width=0')
      end
    end
    delete_buffer(bufnr)
  end)
end)
