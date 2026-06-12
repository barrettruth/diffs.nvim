require('spec.helpers')

local commands = require('diffs.commands')
local generated = require('diffs.generated')

local saved_notify
local notifications = {}

local function capture_notify()
  saved_notify = vim.notify
  notifications = {}
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
end

local function restore_notify()
  if saved_notify then
    vim.notify = saved_notify
    saved_notify = nil
  end
end

---@return string?
local function last_message()
  local entry = notifications[#notifications]
  return entry and entry.msg
end

---@param needle string
---@return boolean
local function last_message_has(needle)
  local msg = last_message()
  return msg ~= nil and msg:find(needle, 1, true) ~= nil
end

local function diff_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function has_line(bufnr, pattern)
  for _, line in ipairs(diff_lines(bufnr)) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

describe('diffs.commands.diff_files', function()
  local dir
  local a
  local b

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    a = dir .. '/a.txt'
    b = dir .. '/b.txt'
    vim.fn.writefile({ 'alpha', 'beta', 'gamma' }, a)
    vim.fn.writefile({ 'alpha', 'BETA', 'gamma', 'delta' }, b)
    capture_notify()
  end)

  after_each(function()
    restore_notify()
    -- Let the scheduled runtime.attach run while the buffers are still valid.
    vim.wait(20, function()
      return false
    end)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match('^diffs://') then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.fn.delete(dir, 'rf')
  end)

  it('renders a read-only unified diff of two files outside any repo', function()
    local bufnr = commands.diff_files(a, b, { layout = 'unified' })

    assert.is_number(bufnr)
    assert.are.equal('diff', vim.bo[bufnr].filetype)
    assert.is_false(vim.bo[bufnr].modifiable)
    assert.is_true(has_line(bufnr, 'diff %-%-git a/.*a%.txt b/.*b%.txt'))
    assert.is_true(has_line(bufnr, '^.*%+BETA'))

    local source = generated.source(bufnr)
    assert.are.equal('files', source.kind)
    assert.are.equal(a, source.left_path)
    assert.are.equal(b, source.right_path)
  end)

  it('defaults the new side to the current buffer with a single path', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(a))
    local bufnr = commands.diff_files(b, nil, { layout = 'unified' })

    assert.is_number(bufnr)
    local source = generated.source(bufnr)
    assert.are.equal(b, source.left_path)
    assert.are.equal(a, source.right_path)
  end)

  it('reloads from disk through the files source', function()
    local bufnr = commands.diff_files(a, b, { layout = 'unified' })
    assert.is_number(bufnr)

    vim.fn.writefile({ 'alpha', 'beta', 'gamma', 'delta', 'epsilon' }, b)
    commands.read_buffer(bufnr)

    assert.is_true(has_line(bufnr, '^.*%+epsilon'))
  end)

  it('reports no changes for identical files without opening a buffer', function()
    local bufnr = commands.diff_files(a, a, { layout = 'unified' })

    assert.is_nil(bufnr)
    local name = vim.fn.fnamemodify(a, ':~:.')
    assert.is_true(last_message_has('no changes between ' .. name .. ' and ' .. name))
  end)

  it('refuses a directory', function()
    local bufnr = commands.diff_files(dir, b, { layout = 'unified' })

    assert.is_nil(bufnr)
    assert.is_true(last_message_has('is a directory; :Diff files compares two files'))
  end)

  it('refuses an unreadable path', function()
    local bufnr = commands.diff_files(dir .. '/missing.txt', b, { layout = 'unified' })

    assert.is_nil(bufnr)
    assert.is_true(last_message_has('missing.txt: file not readable'))
  end)
end)

describe('diffs.commands.diff_files_command', function()
  before_each(capture_notify)
  after_each(restore_notify)

  it('refuses the split layout', function()
    local result = commands.diff_files_command('++layout=split a.txt b.txt', false)

    assert.is_nil(result)
    assert.is_true(last_message_has('split layout is not supported for :Diff files'))
  end)

  it('surfaces parser errors', function()
    local result = commands.diff_files_command('a b c', false)

    assert.is_nil(result)
    assert.is_true(last_message_has('expected at most two file paths'))
  end)
end)
