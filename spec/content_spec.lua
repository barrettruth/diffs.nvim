require('spec.helpers')

local content = require('diffs.content')

local test_buffers = {}
local test_files = {}

local function edit_temp_file(lines, flags)
  local path = vim.fn.tempname()
  test_files[#test_files + 1] = path
  vim.fn.writefile(lines, path, flags or '')
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  test_buffers[#test_buffers + 1] = bufnr
  return content.from_buffer(bufnr)
end

describe('diffs.content', function()
  after_each(function()
    for _, bufnr in ipairs(test_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    test_buffers = {}
    for _, path in ipairs(test_files) do
      vim.fn.delete(path)
    end
    test_files = {}
  end)

  it('normalizes one final newline sentinel', function()
    local lines = content.from_raw_lines({ 'a', '' })

    assert.are.equal(1, #lines)
    assert.are.equal('a', lines[1])
    assert.are.equal('a\n', content.to_string(lines))
  end)

  it('preserves an intentional trailing blank line', function()
    local lines = content.from_raw_lines({ 'a', '', '' })

    assert.are.equal(2, #lines)
    assert.are.equal('a', lines[1])
    assert.are.equal('', lines[2])
    assert.are.equal('a\n\n', content.to_string(lines))
  end)

  it('preserves content without a final newline', function()
    local lines = content.from_raw_lines({ 'a' })

    assert.are.equal(1, #lines)
    assert.are.equal('a', lines[1])
    assert.are.equal('a', content.to_string(lines))
  end)

  it('normalizes empty file reads separately from one-newline files', function()
    local empty = content.from_raw_lines({ '' }, { empty_is_empty = true })
    local newline = content.from_raw_lines({ '', '' })

    assert.are.equal('', content.to_string(empty))
    assert.are.equal('\n', content.to_string(newline))
  end)

  it('preserves buffer final-newline state', function()
    assert.are.equal('', content.to_string(edit_temp_file({}, 'b')))
    assert.are.equal('\n', content.to_string(edit_temp_file({ '' })))
    assert.are.equal('a', content.to_string(edit_temp_file({ 'a' }, 'b')))
    assert.are.equal('a\n', content.to_string(edit_temp_file({ 'a' })))
  end)
end)
