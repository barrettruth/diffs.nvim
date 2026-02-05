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

    it('parses renamed file and returns new name', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  oldname.lua -> newname.lua',
      })
      local filename, section = fugitive.get_file_at_line(buf, 2)
      assert.equals('newname.lua', filename)
      assert.equals('staged', section)
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
      local filename, section = fugitive.get_file_at_line(buf, 1)
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
end)
