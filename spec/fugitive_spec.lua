require('spec.helpers')

local fugitive = require('diffs.fugitive')

describe('fugitive', function()
  describe('get_section_at_line', function()
    local function create_status_buffer(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    it('returns staged for lines in Staged section', function()
      local buf = create_status_buffer({
        'Head: main',
        '',
        'Staged (2)',
        'M  file1.lua',
        'A  file2.lua',
        '',
        'Unstaged (1)',
        'M  file3.lua',
      })
      assert.equals('staged', fugitive.get_section_at_line(buf, 4))
      assert.equals('staged', fugitive.get_section_at_line(buf, 5))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns unstaged for lines in Unstaged section', function()
      local buf = create_status_buffer({
        'Head: main',
        '',
        'Staged (1)',
        'M  file1.lua',
        '',
        'Unstaged (2)',
        'M  file2.lua',
        'M  file3.lua',
      })
      assert.equals('unstaged', fugitive.get_section_at_line(buf, 7))
      assert.equals('unstaged', fugitive.get_section_at_line(buf, 8))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns untracked for lines in Untracked section', function()
      local buf = create_status_buffer({
        'Head: main',
        '',
        'Untracked (2)',
        '?  newfile.lua',
        '?  another.lua',
      })
      assert.equals('untracked', fugitive.get_section_at_line(buf, 4))
      assert.equals('untracked', fugitive.get_section_at_line(buf, 5))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns nil for lines before any section', function()
      local buf = create_status_buffer({
        'Head: main',
        'Push: origin/main',
        '',
        'Staged (1)',
        'M  file1.lua',
      })
      assert.is_nil(fugitive.get_section_at_line(buf, 1))
      assert.is_nil(fugitive.get_section_at_line(buf, 2))
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe('get_file_at_line', function()
    local function create_status_buffer(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    it('parses simple modified file', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  src/foo.lua',
      })
      local filename, section = fugitive.get_file_at_line(buf, 2)
      assert.equals('src/foo.lua', filename)
      assert.equals('unstaged', section)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('parses added file', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'A  newfile.lua',
      })
      local filename, section = fugitive.get_file_at_line(buf, 2)
      assert.equals('newfile.lua', filename)
      assert.equals('staged', section)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('parses deleted file', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'D  oldfile.lua',
      })
      local filename, section = fugitive.get_file_at_line(buf, 2)
      assert.equals('oldfile.lua', filename)
      assert.equals('staged', section)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('parses renamed file and returns both names', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  oldname.lua -> newname.lua',
      })
      local filename, section, is_header, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('newname.lua', filename)
      assert.equals('staged', section)
      assert.is_false(is_header)
      assert.equals('oldname.lua', old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('parses renamed file with similarity index', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R100  old.lua -> new.lua',
      })
      local filename, section, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('new.lua', filename)
      assert.equals('staged', section)
      assert.equals('old.lua', old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns nil old_filename for non-renames', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'M  modified.lua',
      })
      local filename, section, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('modified.lua', filename)
      assert.equals('staged', section)
      assert.is_nil(old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles renamed file with spaces in name', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  old file.lua -> new file.lua',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('new file.lua', filename)
      assert.equals('old file.lua', old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles renamed file in subdirectory', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  src/old.lua -> src/new.lua',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('src/new.lua', filename)
      assert.equals('src/old.lua', old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles renamed file moved to different directory', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  old/file.lua -> new/file.lua',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('new/file.lua', filename)
      assert.equals('old/file.lua', old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('KNOWN LIMITATION: filename containing arrow parsed incorrectly', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  a -> b.lua -> c.lua',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('b.lua -> c.lua', filename)
      assert.equals('a', old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles double extensions', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'M  test.spec.lua',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('test.spec.lua', filename)
      assert.is_nil(old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles hyphenated filenames', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  my-component-test.lua',
      })
      local filename, section = fugitive.get_file_at_line(buf, 2)
      assert.equals('my-component-test.lua', filename)
      assert.equals('unstaged', section)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles underscores and numbers', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'A  test_file_123.lua',
      })
      local filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('test_file_123.lua', filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles dotfiles', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  .gitignore',
      })
      local filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('.gitignore', filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles renamed with complex names', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  src/old-file.spec.lua -> src/new-file.spec.lua',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('src/new-file.spec.lua', filename)
      assert.equals('src/old-file.spec.lua', old_filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles deeply nested paths', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  lua/diffs/ui/components/diff-view.lua',
      })
      local filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('lua/diffs/ui/components/diff-view.lua', filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('parses untracked file', function()
      local buf = create_status_buffer({
        'Untracked (1)',
        '?  untracked.lua',
      })
      local filename, section = fugitive.get_file_at_line(buf, 2)
      assert.equals('untracked.lua', filename)
      assert.equals('untracked', section)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns nil for section header', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
      })
      local filename = fugitive.get_file_at_line(buf, 1)
      assert.is_nil(filename)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('walks back from hunk line to find file', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      })
      local filename, section = fugitive.get_file_at_line(buf, 5)
      assert.equals('file.lua', filename)
      assert.equals('unstaged', section)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles file with both staged and unstaged indicator', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'M  both.lua',
        '',
        'Unstaged (1)',
        'M  both.lua',
      })
      local filename1, section1 = fugitive.get_file_at_line(buf, 2)
      assert.equals('both.lua', filename1)
      assert.equals('staged', section1)

      local filename2, section2 = fugitive.get_file_at_line(buf, 5)
      assert.equals('both.lua', filename2)
      assert.equals('unstaged', section2)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('detects section header for Staged', function()
      local buf = create_status_buffer({
        'Head: main',
        '',
        'Staged (2)',
        'M  file1.lua',
      })
      local filename, section, is_header = fugitive.get_file_at_line(buf, 3)
      assert.is_nil(filename)
      assert.equals('staged', section)
      assert.is_true(is_header)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('detects section header for Unstaged', function()
      local buf = create_status_buffer({
        'Unstaged (3)',
        'M  file1.lua',
      })
      local filename, section, is_header = fugitive.get_file_at_line(buf, 1)
      assert.is_nil(filename)
      assert.equals('unstaged', section)
      assert.is_true(is_header)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('detects section header for Untracked', function()
      local buf = create_status_buffer({
        'Untracked (1)',
        '?  newfile.lua',
      })
      local filename, section, is_header = fugitive.get_file_at_line(buf, 1)
      assert.is_nil(filename)
      assert.equals('untracked', section)
      assert.is_true(is_header)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns is_header=false for file lines', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'M  file.lua',
      })
      local filename, section, is_header = fugitive.get_file_at_line(buf, 2)
      assert.equals('file.lua', filename)
      assert.equals('staged', section)
      assert.is_false(is_header)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)

  describe('get_hunk_position', function()
    local function create_status_buffer(lines)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return buf
    end

    it('returns nil when on file header line', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
      })
      local pos = fugitive.get_hunk_position(buf, 2)
      assert.is_nil(pos)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns nil when on @@ header line', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
      })
      local pos = fugitive.get_hunk_position(buf, 3)
      assert.is_nil(pos)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns hunk header and offset for + line', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      })
      local pos = fugitive.get_hunk_position(buf, 5)
      assert.is_not_nil(pos)
      assert.equals('@@ -1,3 +1,4 @@', pos.hunk_header)
      assert.equals(2, pos.offset)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns hunk header and offset for - line', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        '@@ -1,3 +1,3 @@',
        ' local M = {}',
        '-local old = false',
        ' return M',
      })
      local pos = fugitive.get_hunk_position(buf, 5)
      assert.is_not_nil(pos)
      assert.equals('@@ -1,3 +1,3 @@', pos.hunk_header)
      assert.equals(2, pos.offset)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns hunk header and offset for context line', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      })
      local pos = fugitive.get_hunk_position(buf, 6)
      assert.is_not_nil(pos)
      assert.equals('@@ -1,3 +1,4 @@', pos.hunk_header)
      assert.equals(3, pos.offset)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns correct offset for first line after @@', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
      })
      local pos = fugitive.get_hunk_position(buf, 4)
      assert.is_not_nil(pos)
      assert.equals(1, pos.offset)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('handles @@ header with context text', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        '@@ -10,3 +10,4 @@ function M.hello()',
        '   print("hi")',
        '+  print("world")',
      })
      local pos = fugitive.get_hunk_position(buf, 5)
      assert.is_not_nil(pos)
      assert.equals('@@ -10,3 +10,4 @@ function M.hello()', pos.hunk_header)
      assert.equals(2, pos.offset)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it('returns nil when section header interrupts search', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        ' some orphan line',
      })
      local pos = fugitive.get_hunk_position(buf, 3)
      assert.is_nil(pos)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
