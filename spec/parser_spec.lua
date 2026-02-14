require('spec.helpers')
local parser = require('diffs.parser')

describe('parser', function()
  describe('parse_buffer', function()
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

    it('returns empty table for empty buffer', function()
      local bufnr = create_buffer({})
      local hunks = parser.parse_buffer(bufnr)
      assert.are.same({}, hunks)
      delete_buffer(bufnr)
    end)

    it('returns empty table for buffer with no hunks', function()
      local bufnr = create_buffer({
        'Head: main',
        'Help: g?',
        '',
        'Unstaged (1)',
        'M lua/test.lua',
      })
      local hunks = parser.parse_buffer(bufnr)
      assert.are.same({}, hunks)
      delete_buffer(bufnr)
    end)

    it('detects single hunk with lua file', function()
      local bufnr = create_buffer({
        'Unstaged (1)',
        'M lua/test.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('lua/test.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].ft)
      assert.are.equal('lua', hunks[1].lang)
      assert.are.equal(3, hunks[1].start_line)
      assert.are.equal(3, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('detects multiple hunks in same file', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -1,2 +1,2 @@',
        ' local M = {}',
        '-local old = false',
        '+local new = true',
        '@@ -10,2 +10,3 @@',
        ' function M.foo()',
        '+  print("hello")',
        ' end',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(2, #hunks)
      assert.are.equal(2, hunks[1].start_line)
      assert.are.equal(6, hunks[2].start_line)
      delete_buffer(bufnr)
    end)

    it('detects hunks across multiple files', function()
      local orig_get_lang = vim.treesitter.language.get_lang
      local orig_inspect = vim.treesitter.language.inspect
      vim.treesitter.language.get_lang = function(ft)
        local result = orig_get_lang(ft)
        if result then
          return result
        end
        if ft == 'python' then
          return 'python'
        end
        return nil
      end
      vim.treesitter.language.inspect = function(lang)
        if lang == 'python' then
          return {}
        end
        return orig_inspect(lang)
      end

      local bufnr = create_buffer({
        'M lua/foo.lua',
        '@@ -1,1 +1,2 @@',
        ' local M = {}',
        '+local x = 1',
        'M src/bar.py',
        '@@ -1,1 +1,2 @@',
        ' def hello():',
        '+    pass',
      })
      local hunks = parser.parse_buffer(bufnr)

      vim.treesitter.language.get_lang = orig_get_lang
      vim.treesitter.language.inspect = orig_inspect

      assert.are.equal(2, #hunks)
      assert.are.equal('lua/foo.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].lang)
      assert.are.equal('src/bar.py', hunks[2].filename)
      assert.are.equal('python', hunks[2].lang)
      delete_buffer(bufnr)
    end)

    it('extracts header context', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -10,3 +10,4 @@ function M.hello()',
        ' local msg = "hi"',
        '+print(msg)',
        ' end',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('function M.hello()', hunks[1].header_context)
      assert.is_not_nil(hunks[1].header_context_col)
      delete_buffer(bufnr)
    end)

    it('handles header without context', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.is_nil(hunks[1].header_context)
      delete_buffer(bufnr)
    end)

    it('handles all git status prefixes', function()
      local prefixes = { 'M', 'A', 'D', 'R', 'C', '?', '!' }
      for _, prefix in ipairs(prefixes) do
        local bufnr = create_buffer({
          prefix .. ' test.lua',
          '@@ -1,1 +1,2 @@',
          ' local x = 1',
          '+local y = 2',
        })
        local hunks = parser.parse_buffer(bufnr)
        assert.are.equal(1, #hunks, 'Failed for prefix: ' .. prefix)
        delete_buffer(bufnr)
      end
    end)

    it('stops hunk at blank line', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        '+local y = 2',
        '',
        'Some other content',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(2, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('emits hunk with ft when no ts parser available', function()
      local bufnr = create_buffer({
        'M test.xyz_no_parser',
        '@@ -1,1 +1,2 @@',
        ' some content',
        '+more content',
      })

      vim.filetype.add({ extension = { xyz_no_parser = 'xyz_no_parser_ft' } })

      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('xyz_no_parser_ft', hunks[1].ft)
      assert.is_nil(hunks[1].lang)
      assert.are.equal(2, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('stops hunk at next file header', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        '+local y = 2',
        'M other.lua',
        '@@ -1,1 +1,1 @@',
        ' local z = 3',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(2, #hunks)
      assert.are.equal(2, #hunks[1].lines)
      assert.are.equal(1, #hunks[2].lines)
      delete_buffer(bufnr)
    end)

    it('attaches header_lines to first hunk only', function()
      local bufnr = create_buffer({
        'diff --git a/parser.lua b/parser.lua',
        'index 3e8afa0..018159c 100644',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
        '@@ -10,2 +11,3 @@',
        ' function M.foo()',
        '+  return true',
        ' end',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(2, #hunks)
      assert.is_not_nil(hunks[1].header_start_line)
      assert.is_not_nil(hunks[1].header_lines)
      assert.are.equal(1, hunks[1].header_start_line)
      assert.is_nil(hunks[2].header_start_line)
      assert.is_nil(hunks[2].header_lines)
      delete_buffer(bufnr)
    end)

    it('header_lines contains only diff metadata, not hunk content', function()
      local bufnr = create_buffer({
        'diff --git a/parser.lua b/parser.lua',
        'index 3e8afa0..018159c 100644',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(4, #hunks[1].header_lines)
      assert.are.equal('diff --git a/parser.lua b/parser.lua', hunks[1].header_lines[1])
      assert.are.equal('index 3e8afa0..018159c 100644', hunks[1].header_lines[2])
      assert.are.equal('--- a/parser.lua', hunks[1].header_lines[3])
      assert.are.equal('+++ b/parser.lua', hunks[1].header_lines[4])
      delete_buffer(bufnr)
    end)

    it('handles fugitive status format with diff headers', function()
      local bufnr = create_buffer({
        'Head: main',
        'Push: origin/main',
        '',
        'Unstaged (1)',
        'M parser.lua',
        'diff --git a/parser.lua b/parser.lua',
        'index 3e8afa0..018159c 100644',
        '--- a/parser.lua',
        '+++ b/parser.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(6, hunks[1].header_start_line)
      assert.are.equal(4, #hunks[1].header_lines)
      assert.are.equal('diff --git a/parser.lua b/parser.lua', hunks[1].header_lines[1])
      delete_buffer(bufnr)
    end)

    it('emits hunk for files with unknown filetype', function()
      local bufnr = create_buffer({
        'M config.obscuretype',
        '@@ -1,2 +1,3 @@',
        ' setting1 = value1',
        '-setting2 = value2',
        '+setting2 = MODIFIED',
        '+setting4 = newvalue',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('config.obscuretype', hunks[1].filename)
      assert.is_nil(hunks[1].ft)
      assert.is_nil(hunks[1].lang)
      assert.are.equal(4, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('uses filetype from existing buffer when available', function()
      local repo_root = '/tmp/test-repo'
      local file_path = repo_root .. '/build'

      local file_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(file_buf, file_path)
      vim.api.nvim_set_option_value('filetype', 'bash', { buf = file_buf })

      local diff_buf = create_buffer({
        'M build',
        '@@ -1,2 +1,3 @@',
        ' echo "hello"',
        '+set -e',
        ' echo "done"',
      })
      vim.api.nvim_buf_set_var(diff_buf, 'diffs_repo_root', repo_root)

      local hunks = parser.parse_buffer(diff_buf)

      assert.are.equal(1, #hunks)
      assert.are.equal('build', hunks[1].filename)
      assert.are.equal('bash', hunks[1].ft)

      delete_buffer(file_buf)
      delete_buffer(diff_buf)
    end)

    it('uses filetype from existing buffer via git_dir', function()
      local git_dir = '/tmp/test-repo/.git'
      local repo_root = '/tmp/test-repo'
      local file_path = repo_root .. '/script'

      local file_buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_name(file_buf, file_path)
      vim.api.nvim_set_option_value('filetype', 'python', { buf = file_buf })

      local diff_buf = create_buffer({
        'M script',
        '@@ -1,2 +1,3 @@',
        ' def main():',
        '+    print("hi")',
        '     pass',
      })
      vim.api.nvim_buf_set_var(diff_buf, 'git_dir', git_dir)

      local hunks = parser.parse_buffer(diff_buf)

      assert.are.equal(1, #hunks)
      assert.are.equal('script', hunks[1].filename)
      assert.are.equal('python', hunks[1].ft)

      delete_buffer(file_buf)
      delete_buffer(diff_buf)
    end)

    it('detects filetype from file content shebang without open buffer', function()
      local repo_root = '/tmp/diffs-test-shebang'
      vim.fn.mkdir(repo_root, 'p')

      local file_path = repo_root .. '/build'
      local f = io.open(file_path, 'w')
      f:write('#!/bin/bash\n')
      f:write('set -e\n')
      f:write('echo "hello"\n')
      f:close()

      local diff_buf = create_buffer({
        'M build',
        '@@ -1,2 +1,3 @@',
        ' #!/bin/bash',
        '+set -e',
        ' echo "hello"',
      })
      vim.api.nvim_buf_set_var(diff_buf, 'diffs_repo_root', repo_root)

      local hunks = parser.parse_buffer(diff_buf)

      assert.are.equal(1, #hunks)
      assert.are.equal('build', hunks[1].filename)
      assert.are.equal('sh', hunks[1].ft)

      delete_buffer(diff_buf)
      os.remove(file_path)
      vim.fn.delete(repo_root, 'rf')
    end)

    it('extracts file line numbers from @@ header', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(1, hunks[1].file_old_start)
      assert.are.equal(3, hunks[1].file_old_count)
      assert.are.equal(1, hunks[1].file_new_start)
      assert.are.equal(4, hunks[1].file_new_count)
      delete_buffer(bufnr)
    end)

    it('defaults count to 1 when omitted in @@ header', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -1 +1 @@',
        ' local M = {}',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(1, hunks[1].file_old_start)
      assert.are.equal(1, hunks[1].file_old_count)
      assert.are.equal(1, hunks[1].file_new_start)
      assert.are.equal(1, hunks[1].file_new_count)
      delete_buffer(bufnr)
    end)

    it('recognizes U prefix for unmerged files', function()
      local bufnr = create_buffer({
        'U merge_me.lua',
        '@@@ -1,3 -1,5 +1,9 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        ' +  return 1',
        '++=======',
        '+   return 2',
        '++>>>>>>> feature',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('merge_me.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].ft)
      delete_buffer(bufnr)
    end)

    it('sets prefix_width 2 from @@@ combined diff header', function()
      local bufnr = create_buffer({
        'U test.lua',
        '@@@ -1,3 -1,5 +1,9 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        ' +  return 1',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(2, hunks[1].prefix_width)
      delete_buffer(bufnr)
    end)

    it('sets prefix_width 1 for standard @@ unified diff', function()
      local bufnr = create_buffer({
        'M test.lua',
        '@@ -1,2 +1,3 @@',
        ' local x = 1',
        '+local y = 2',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(1, hunks[1].prefix_width)
      delete_buffer(bufnr)
    end)

    it('collects all combined diff line types as hunk content', function()
      local bufnr = create_buffer({
        'U test.lua',
        '@@@ -1,3 -1,3 +1,5 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        ' +  return 1',
        '+ local x = 2',
        '  end',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(5, #hunks[1].lines)
      assert.are.equal('  local M = {}', hunks[1].lines[1])
      assert.are.equal('++<<<<<<< HEAD', hunks[1].lines[2])
      assert.are.equal(' +  return 1', hunks[1].lines[3])
      assert.are.equal('+ local x = 2', hunks[1].lines[4])
      assert.are.equal('  end', hunks[1].lines[5])
      delete_buffer(bufnr)
    end)

    it('extracts new range from combined diff header', function()
      local bufnr = create_buffer({
        'U test.lua',
        '@@@ -1,3 -1,5 +1,9 @@@',
        '  local M = {}',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal(1, hunks[1].file_new_start)
      assert.are.equal(9, hunks[1].file_new_count)
      assert.is_nil(hunks[1].file_old_start)
      delete_buffer(bufnr)
    end)

    it('extracts header context from combined diff header', function()
      local bufnr = create_buffer({
        'U test.lua',
        '@@@ -1,3 -1,5 +1,9 @@@ function M.greet()',
        '  local M = {}',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('function M.greet()', hunks[1].header_context)
      delete_buffer(bufnr)
    end)

    it('resets prefix_width when switching from combined to unified diff', function()
      local bufnr = create_buffer({
        'U merge.lua',
        '@@@ -1,1 -1,1 +1,3 @@@',
        '  local M = {}',
        '++<<<<<<< HEAD',
        'M other.lua',
        '@@ -1,1 +1,2 @@',
        ' local x = 1',
        '+local y = 2',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(2, #hunks)
      assert.are.equal(2, hunks[1].prefix_width)
      assert.are.equal(1, hunks[2].prefix_width)
      delete_buffer(bufnr)
    end)

    it('parses diff from gitcommit verbose buffer', function()
      local bufnr = create_buffer({
        '',
        '# Please enter the commit message for your changes.',
        '#',
        '# On branch main',
        '# Changes to be committed:',
        '#\tmodified:   test.lua',
        '#',
        '# ------------------------ >8 ------------------------',
        '# Do not modify or remove the line above.',
        'diff --git a/test.lua b/test.lua',
        'index abc1234..def5678 100644',
        '--- a/test.lua',
        '+++ b/test.lua',
        '@@ -1,3 +1,3 @@',
        ' local function hello()',
        '-  print("hello world")',
        '+  print("hello universe")',
        '   return true',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('test.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].ft)
      assert.are.equal(4, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('stores repo_root on hunk when available', function()
      local bufnr = create_buffer({
        'M lua/test.lua',
        '@@ -1,3 +1,4 @@',
        ' local M = {}',
        '+local new = true',
        ' return M',
      })
      vim.api.nvim_buf_set_var(bufnr, 'diffs_repo_root', '/tmp/test-repo')
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('/tmp/test-repo', hunks[1].repo_root)
      delete_buffer(bufnr)
    end)

    it('detects neogit modified prefix', function()
      local bufnr = create_buffer({
        'modified   hello.lua',
        '@@ -1,2 +1,3 @@',
        ' local M = {}',
        '+local x = 1',
        ' return M',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('hello.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].ft)
      assert.are.equal(3, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('detects neogit new file prefix', function()
      local bufnr = create_buffer({
        'new file   hello.lua',
        '@@ -0,0 +1,2 @@',
        '+local M = {}',
        '+return M',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('hello.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].ft)
      assert.are.equal(2, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('detects neogit deleted prefix', function()
      local bufnr = create_buffer({
        'deleted   hello.lua',
        '@@ -1,2 +0,0 @@',
        '-local M = {}',
        '-return M',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('hello.lua', hunks[1].filename)
      assert.are.equal('lua', hunks[1].ft)
      assert.are.equal(2, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('detects bare filename for untracked files', function()
      local bufnr = create_buffer({
        'newfile.rs',
        '@@ -0,0 +1,3 @@',
        '+fn main() {',
        '+    println!("hello");',
        '+}',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('newfile.rs', hunks[1].filename)
      assert.are.equal(3, #hunks[1].lines)
      delete_buffer(bufnr)
    end)

    it('does not match section headers as bare filenames', function()
      local bufnr = create_buffer({
        'Untracked files (1)',
        'newfile.rs',
        '@@ -0,0 +1,3 @@',
        '+fn main() {',
        '+    println!("hello");',
        '+}',
      })
      local hunks = parser.parse_buffer(bufnr)

      assert.are.equal(1, #hunks)
      assert.are.equal('newfile.rs', hunks[1].filename)
      delete_buffer(bufnr)
    end)
  end)
end)
