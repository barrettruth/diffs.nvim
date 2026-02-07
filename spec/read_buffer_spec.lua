require('spec.helpers')

local commands = require('diffs.commands')
local diffs = require('diffs')
local git = require('diffs.git')

local saved_git = {}
local saved_systemlist
local test_buffers = {}

local function mock_git(overrides)
  overrides = overrides or {}
  saved_git.get_file_content = git.get_file_content
  saved_git.get_index_content = git.get_index_content
  saved_git.get_working_content = git.get_working_content

  git.get_file_content = overrides.get_file_content
    or function()
      return { 'local M = {}', 'return M' }
    end
  git.get_index_content = overrides.get_index_content
    or function()
      return { 'local M = {}', 'return M' }
    end
  git.get_working_content = overrides.get_working_content
    or function()
      return { 'local M = {}', 'local x = 1', 'return M' }
    end
end

local function mock_systemlist(fn)
  saved_systemlist = vim.fn.systemlist
  vim.fn.systemlist = function(cmd)
    local result = fn(cmd)
    saved_systemlist({ 'true' })
    return result
  end
end

local function restore_mocks()
  for k, v in pairs(saved_git) do
    git[k] = v
  end
  saved_git = {}
  if saved_systemlist then
    vim.fn.systemlist = saved_systemlist
    saved_systemlist = nil
  end
end

---@param name string
---@param vars? table<string, any>
---@return integer
local function create_diffs_buffer(name, vars)
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then
    vim.api.nvim_buf_delete(existing, { force = true })
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vars = vars or {}
  for k, v in pairs(vars) do
    vim.api.nvim_buf_set_var(bufnr, k, v)
  end
  table.insert(test_buffers, bufnr)
  return bufnr
end

local function cleanup_buffers()
  for _, bufnr in ipairs(test_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end
  test_buffers = {}
end

describe('read_buffer', function()
  after_each(function()
    restore_mocks()
    cleanup_buffers()
  end)

  describe('early returns', function()
    it('does nothing on non-diffs:// buffer', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      table.insert(test_buffers, bufnr)
      assert.has_no.errors(function()
        commands.read_buffer(bufnr)
      end)
      assert.are.same({ '' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it('does nothing on malformed url without colon separator', function()
      local bufnr = create_diffs_buffer('diffs://nocolonseparator')
      vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', '/tmp')
      local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.has_no.errors(function()
        commands.read_buffer(bufnr)
      end)
      assert.are.same(lines_before, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)

    it('does nothing when diffs_repo_root is missing', function()
      local bufnr = create_diffs_buffer('diffs://staged:missing_root.lua')
      assert.has_no.errors(function()
        commands.read_buffer(bufnr)
      end)
      assert.are.same({ '' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end)
  end)

  describe('buffer options', function()
    it('sets buftype, bufhidden, swapfile, modifiable, filetype', function()
      mock_git()
      local bufnr = create_diffs_buffer('diffs://staged:options_test.lua', {
        diffs_repo_root = '/tmp',
      })

      commands.read_buffer(bufnr)

      assert.are.equal('nowrite', vim.api.nvim_get_option_value('buftype', { buf = bufnr }))
      assert.are.equal('delete', vim.api.nvim_get_option_value('bufhidden', { buf = bufnr }))
      assert.is_false(vim.api.nvim_get_option_value('swapfile', { buf = bufnr }))
      assert.is_false(vim.api.nvim_get_option_value('modifiable', { buf = bufnr }))
      assert.are.equal('diff', vim.api.nvim_get_option_value('filetype', { buf = bufnr }))
    end)
  end)

  describe('dispatch', function()
    it('calls get_file_content + get_index_content for staged label', function()
      local called_get_file = false
      local called_get_index = false
      mock_git({
        get_file_content = function()
          called_get_file = true
          return { 'old' }
        end,
        get_index_content = function()
          called_get_index = true
          return { 'new' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://staged:dispatch_staged.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.is_true(called_get_file)
      assert.is_true(called_get_index)
    end)

    it('calls get_index_content + get_working_content for unstaged label', function()
      local called_get_index = false
      local called_get_working = false
      mock_git({
        get_index_content = function()
          called_get_index = true
          return { 'index' }
        end,
        get_working_content = function()
          called_get_working = true
          return { 'working' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://unstaged:dispatch_unstaged.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.is_true(called_get_index)
      assert.is_true(called_get_working)
    end)

    it('calls only get_working_content for untracked label', function()
      local called_get_file = false
      local called_get_working = false
      mock_git({
        get_file_content = function()
          called_get_file = true
          return {}
        end,
        get_working_content = function()
          called_get_working = true
          return { 'new file' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://untracked:dispatch_untracked.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.is_false(called_get_file)
      assert.is_true(called_get_working)
    end)

    it('calls get_file_content + get_working_content for revision label', function()
      local captured_rev
      local called_get_working = false
      mock_git({
        get_file_content = function(rev)
          captured_rev = rev
          return { 'old' }
        end,
        get_working_content = function()
          called_get_working = true
          return { 'new' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://HEAD~3:dispatch_rev.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.are.equal('HEAD~3', captured_rev)
      assert.is_true(called_get_working)
    end)

    it('falls back from index to HEAD for unstaged when index returns nil', function()
      local call_order = {}
      mock_git({
        get_index_content = function()
          table.insert(call_order, 'index')
          return nil
        end,
        get_file_content = function()
          table.insert(call_order, 'head')
          return { 'head content' }
        end,
        get_working_content = function()
          return { 'working content' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://unstaged:dispatch_fallback.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.are.same({ 'index', 'head' }, call_order)
    end)

    it('runs git diff for section diffs with path=all', function()
      local captured_cmd
      mock_systemlist(function(cmd)
        captured_cmd = cmd
        return {
          'diff --git a/file.lua b/file.lua',
          '--- a/file.lua',
          '+++ b/file.lua',
          '@@ -1 +1 @@',
          '-old',
          '+new',
        }
      end)

      local bufnr = create_diffs_buffer('diffs://unstaged:all', {
        diffs_repo_root = '/home/test/repo',
      })
      commands.read_buffer(bufnr)

      assert.is_not_nil(captured_cmd)
      assert.are.equal('git', captured_cmd[1])
      assert.are.equal('/home/test/repo', captured_cmd[3])
      assert.are.equal('diff', captured_cmd[4])

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('diff --git a/file.lua b/file.lua', lines[1])
    end)

    it('passes --cached for staged section diffs', function()
      local captured_cmd
      mock_systemlist(function(cmd)
        captured_cmd = cmd
        return { 'diff --git a/f.lua b/f.lua', '@@ -1 +1 @@', '-a', '+b' }
      end)

      local bufnr = create_diffs_buffer('diffs://staged:all', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.is_truthy(vim.tbl_contains(captured_cmd, '--cached'))
    end)
  end)

  describe('content', function()
    it('generates valid unified diff header with correct paths', function()
      mock_git({
        get_file_content = function()
          return { 'old' }
        end,
        get_working_content = function()
          return { 'new' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://HEAD:lua/diffs/init.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('diff --git a/lua/diffs/init.lua b/lua/diffs/init.lua', lines[1])
      assert.are.equal('--- a/lua/diffs/init.lua', lines[2])
      assert.are.equal('+++ b/lua/diffs/init.lua', lines[3])
    end)

    it('uses old_filepath for diff header in renames', function()
      mock_git({
        get_file_content = function(_, path)
          assert.are.equal('/tmp/old_name.lua', path)
          return { 'old content' }
        end,
        get_index_content = function()
          return { 'new content' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://staged:new_name.lua', {
        diffs_repo_root = '/tmp',
        diffs_old_filepath = 'old_name.lua',
      })
      commands.read_buffer(bufnr)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('diff --git a/old_name.lua b/new_name.lua', lines[1])
      assert.are.equal('--- a/old_name.lua', lines[2])
      assert.are.equal('+++ b/new_name.lua', lines[3])
    end)

    it('produces empty buffer when old and new are identical', function()
      mock_git({
        get_file_content = function()
          return { 'identical' }
        end,
        get_working_content = function()
          return { 'identical' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://HEAD:nodiff.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.same({ '' }, lines)
    end)

    it('replaces existing buffer content on reload', function()
      mock_git({
        get_file_content = function()
          return { 'old' }
        end,
        get_working_content = function()
          return { 'new' }
        end,
      })

      local bufnr = create_diffs_buffer('diffs://HEAD:replace_test.lua', {
        diffs_repo_root = '/tmp',
      })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'stale', 'content', 'from', 'before' })

      commands.read_buffer(bufnr)

      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      assert.are.equal('diff --git a/replace_test.lua b/replace_test.lua', lines[1])
      for _, line in ipairs(lines) do
        assert.is_not_equal('stale', line)
      end
    end)
  end)

  describe('attach integration', function()
    it('calls attach on the buffer', function()
      mock_git()

      local attach_called_with
      local original_attach = diffs.attach
      diffs.attach = function(bufnr)
        attach_called_with = bufnr
      end

      local bufnr = create_diffs_buffer('diffs://staged:attach_test.lua', {
        diffs_repo_root = '/tmp',
      })
      commands.read_buffer(bufnr)

      assert.are.equal(bufnr, attach_called_with)

      diffs.attach = original_attach
    end)
  end)
end)
