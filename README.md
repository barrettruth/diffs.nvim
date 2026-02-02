# fugitive-ts.nvim

Treesitter syntax highlighting for vim-fugitive diff views.

## Problem

vim-fugitive uses regex-based `syntax/diff.vim` for highlighting expanded diffs
in the status buffer. This means code inside diffs has no language-aware
highlighting:

```
Unstaged (1)
M lua/mymodule.lua
@@ -10,3 +10,4 @@
 local M = {}           ← no lua highlighting
+local new_thing = true ← just diff green, no syntax
 return M
```

## Solution

Hook into fugitive's buffer, detect diff hunks, extract the language from
filenames, and apply treesitter highlights as extmarks on top of fugitive's
existing highlighting.

```
Unstaged (1)
M lua/mymodule.lua
@@ -10,3 +10,4 @@
 local M = {}           ← treesitter lua highlights overlaid
+local new_thing = true ← diff green + lua keyword/boolean highlights
 return M
```

## Technical Approach

### 1. Hook Point

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "fugitive",
  callback = function(args)
    -- Set up buffer-local autocmd to re-highlight on changes
    -- (user expanding/collapsing diffs with = key)
  end
})
```

Also consider `User FugitiveIndex` event for more specific timing.

### 2. Parse Fugitive Buffer Structure

The fugitive status buffer has this structure:

```
Head: branch-name
Merge: origin/branch
Help: g?

Unstaged (N)
M path/to/file.lua        ← filename line (extract extension here)
@@ -10,3 +10,4 @@           ← hunk header
 context line              ← code lines start here
+added line
-removed line
 context line              ← code lines end at next blank/header

Staged (N)
...
```

Pattern to detect:

- Filename: `^[MADRC?] .+%.(%w+)$` → captures extension
- Hunk header: `^@@ .+ @@`
- Code lines: after hunk header, lines starting with ` `, `+`, or `-`
- End of hunk: blank line, next filename, or next section header

### 3. Map Extension to Treesitter Language

```lua
local ext_to_lang = {
  lua = "lua",
  py = "python",
  js = "javascript",
  ts = "typescript",
  tsx = "tsx",
  rs = "rust",
  go = "go",
  rb = "ruby",
  -- etc.
}

-- Or use vim.filetype.match() for robustness:
local ft = vim.filetype.match({ filename = filename })
local lang = vim.treesitter.language.get_lang(ft)
```

### 4. Check Parser Availability

```lua
local function has_parser(lang)
  local ok = pcall(vim.treesitter.language.inspect, lang)
  return ok
end
```

If no parser, skip (keep fugitive's default highlighting).

### 5. Apply Treesitter Highlights

Core algorithm:

```lua
local ns = vim.api.nvim_create_namespace("fugitive_ts")

local function highlight_hunk(bufnr, start_line, lines, lang)
  -- Strip the leading +/- /space from each line for parsing
  local code_lines = {}
  local prefix_chars = {}
  for i, line in ipairs(lines) do
    prefix_chars[i] = line:sub(1, 1)
    code_lines[i] = line:sub(2)  -- remove diff prefix
  end

  local code = table.concat(code_lines, "\n")

  -- Parse with treesitter
  local parser = vim.treesitter.get_string_parser(code, lang)
  local tree = parser:parse()[1]
  local root = tree:root()

  -- Get highlight query
  local query = vim.treesitter.query.get(lang, "highlights")
  if not query then return end

  -- Apply highlights
  for id, node, metadata in query:iter_captures(root, code) do
    local capture = "@" .. query.captures[id]
    local sr, sc, er, ec = node:range()

    -- Translate to buffer coordinates
    -- sr/er are 0-indexed rows within the code snippet
    -- Need to add start_line offset and +1 for the prefix char
    local buf_sr = start_line + sr
    local buf_er = start_line + er
    local buf_sc = sc + 1  -- +1 for the +/-/space prefix
    local buf_ec = ec + 1

    vim.api.nvim_buf_set_extmark(bufnr, ns, buf_sr, buf_sc, {
      end_row = buf_er,
      end_col = buf_ec,
      hl_group = capture,
      priority = 200,  -- higher than fugitive's syntax
    })
  end
end
```

### 6. Re-highlight on Buffer Change

Fugitive modifies the buffer when user expands/collapses diffs. Need to
re-parse:

```lua
vim.api.nvim_create_autocmd({"TextChanged", "TextChangedI"}, {
  buffer = bufnr,
  callback = function()
    -- Clear old highlights
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    -- Re-scan and highlight
    highlight_fugitive_buffer(bufnr)
  end
})
```

Consider debouncing for performance.

## File Structure

```
fugitive-ts.nvim/
├── lua/
│   └── fugitive-ts/
│       ├── init.lua      -- setup() and main logic
│       ├── parser.lua    -- parse fugitive buffer structure
│       └── highlight.lua -- treesitter highlight application
└── plugin/
    └── fugitive-ts.lua   -- autocommand setup (lazy load)
```

## API

```lua
require("fugitive-ts").setup({
  -- Enable/disable (default: true)
  enabled = true,

  -- Custom extension -> language mappings
  languages = {
    -- extension = "treesitter-lang"
  },

  -- Fallback to vim syntax if no treesitter parser (default: false)
  -- (More complex to implement - would need to create scratch buffer)
  syntax_fallback = false,
})
```

## Edge Cases

1. **No parser installed**: Skip, keep default highlighting
2. **Unknown extension**: Use `vim.filetype.match()` then `get_lang()`
3. **Binary files**: Fugitive shows "Binary file differs" - no code lines
4. **Very large diffs**: Consider limiting to visible lines only
5. **Multi-byte characters**: Treesitter ranges are byte-based, should work

## Dependencies

- Neovim 0.9+ (treesitter APIs)
- vim-fugitive
- Treesitter parsers for languages you want highlighted

## Performance Considerations

- Only parse visible hunks (check against `vim.fn.line('w0')` / `line('w$')`)
- Debounce TextChanged events (50-100ms)
- Cache parsed trees if buffer hasn't changed
- Use `priority = 200` on extmarks to layer over fugitive syntax

## References

- [Neovim Treesitter API](https://neovim.io/doc/user/treesitter.html)
- [vim-fugitive User events](https://github.com/tpope/vim-fugitive/blob/master/doc/fugitive.txt)
- [nvim_buf_set_extmark](<https://neovim.io/doc/user/api.html#nvim_buf_set_extmark()>)
- [vim.treesitter.get_string_parser](<https://neovim.io/doc/user/treesitter.html#vim.treesitter.get_string_parser()>)
