local helpers = require('spec.helpers')

local fugitive = require('diffs.fugitive')

describe('fugitive', function()
  local test_buffers = {}

  local function create_buffer(lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
    test_buffers[#test_buffers + 1] = buf
    return buf
  end

  after_each(function()
    for _, buf in ipairs(test_buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    test_buffers = {}
  end)

  describe('get_section_at_line', function()
    local function create_status_buffer(lines)
      return create_buffer(lines)
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
    end)
  end)

  describe('get_file_at_line', function()
    local function create_status_buffer(lines)
      return create_buffer(lines)
    end

    it('parses simple modified file', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  src/foo.lua',
      })
      local filename, section = fugitive.get_file_at_line(buf, 2)
      assert.equals('src/foo.lua', filename)
      assert.equals('unstaged', section)
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
    end)

    it('parses copied file with similarity index and returns both names', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'C100  old.lua -> copy.lua',
      })
      local filename, section, _, old_filename, status = fugitive.get_file_at_line(buf, 2)
      assert.equals('copy.lua', filename)
      assert.equals('staged', section)
      assert.equals('old.lua', old_filename)
      assert.equals('C', status)
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
    end)

    it('handles renamed file with spaces in name', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  old file.lua -> new file.lua',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('new file.lua', filename)
      assert.equals('old file.lua', old_filename)
    end)

    it('KNOWN LIMITATION: filename containing arrow parsed incorrectly', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R  a -> b.lua -> c.lua',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('b.lua -> c.lua', filename)
      assert.equals('a', old_filename)
    end)

    it('unquotes git-quoted filenames with spaces', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  "path with spaces/file.lua"',
      })
      local filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('path with spaces/file.lua', filename)
    end)

    it('unquotes escaped quotes in filenames', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  "file\\"name.lua"',
      })
      local filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('file"name.lua', filename)
    end)

    it('unquotes octal escapes in filenames', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  "\\303\\251le.lua"',
      })
      local filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('\195\169le.lua', filename)
    end)

    it('passes through unquoted filenames unchanged', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  normal.lua',
      })
      local filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('normal.lua', filename)
    end)

    it('unquotes renamed files with quotes', function()
      local buf = create_status_buffer({
        'Staged (1)',
        'R100 "old name.lua" -> "new name.lua"',
      })
      local filename, _, _, old_filename = fugitive.get_file_at_line(buf, 2)
      assert.equals('new name.lua', filename)
      assert.equals('old name.lua', old_filename)
    end)

    it('returns nil for section header', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
      })
      local filename = fugitive.get_file_at_line(buf, 1)
      assert.is_nil(filename)
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
    end)
  end)

  describe('get_hunk_position', function()
    local function create_status_buffer(lines)
      return create_buffer(lines)
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
    end)

    it('returns nil when section header interrupts search', function()
      local buf = create_status_buffer({
        'Unstaged (1)',
        'M  file.lua',
        ' some orphan line',
      })
      local pos = fugitive.get_hunk_position(buf, 3)
      assert.is_nil(pos)
    end)
  end)

  describe('setup_keymaps', function()
    it('preserves pre-existing horizontal map and installs vertical map', function()
      local buf = create_buffer()
      vim.keymap.set('n', 'du', '<Nop>', { buffer = buf, desc = 'user horizontal' })

      fugitive.setup_keymaps(buf, { horizontal = 'du', vertical = 'dU' })

      assert.are.equal('user horizontal', helpers.get_keymap(buf, 'du').desc)
      assert.are.equal('Unified diff (vertical)', helpers.get_keymap(buf, 'dU').desc)
    end)

    it('preserves pre-existing vertical map and installs horizontal map', function()
      local buf = create_buffer()
      vim.keymap.set('n', 'dU', '<Nop>', { buffer = buf, desc = 'user vertical' })

      fugitive.setup_keymaps(buf, { horizontal = 'du', vertical = 'dU' })

      assert.are.equal('Unified diff (horizontal)', helpers.get_keymap(buf, 'du').desc)
      assert.are.equal('user vertical', helpers.get_keymap(buf, 'dU').desc)
    end)

    it('does not install disabled or empty maps', function()
      local buf = create_buffer()

      fugitive.setup_keymaps(buf, { horizontal = false, vertical = '' })

      assert.is_false(helpers.has_keymap(buf, 'du'))
      assert.is_false(helpers.has_keymap(buf, 'dU'))
    end)

    it('clears owned maps when disabled later', function()
      local buf = create_buffer()

      fugitive.setup_keymaps(buf, { horizontal = 'du', vertical = 'dU' })
      fugitive.setup_keymaps(buf, { horizontal = false, vertical = false })

      assert.is_false(helpers.has_keymap(buf, 'du'))
      assert.is_false(helpers.has_keymap(buf, 'dU'))
    end)

    it('does not delete maps replaced after diffs.nvim installed them', function()
      local buf = create_buffer()

      fugitive.setup_keymaps(buf, { horizontal = 'du', vertical = 'dU' })
      vim.keymap.set('n', 'du', '<Nop>', { buffer = buf, desc = 'user replacement' })
      fugitive.setup_keymaps(buf, { horizontal = false, vertical = false })

      assert.are.equal('user replacement', helpers.get_keymap(buf, 'du').desc)
      assert.is_false(helpers.has_keymap(buf, 'dU'))
    end)
  end)
end)
