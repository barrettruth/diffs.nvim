# fugitive-ts.nvim

**Treesitter syntax highlighting for vim-fugitive diff views**

Transform fugitive's regex-based diff highlighting into language-aware,
treesitter-powered syntax highlighting.

## Features

- **Language-aware highlighting**: Full treesitter syntax highlighting for code
  in diff hunks
- **Automatic language detection**: Detects language from filenames using
  Neovim's filetype detection
- **Header context highlighting**: Highlights function signatures in hunk
  headers (`@@ ... @@ function foo()`)
- **Performance optimized**: Debounced updates, configurable max lines per hunk
- **Zero configuration**: Works out of the box with sensible defaults

## Requirements

- Neovim 0.9.0+
- [vim-fugitive](https://github.com/tpope/vim-fugitive)
- Treesitter parsers for languages you want highlighted

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'barrettruth/fugitive-ts.nvim',
  dependencies = { 'tpope/vim-fugitive' },
  opts = {},
}
```

## Configuration

```lua
require('fugitive-ts').setup({
  enabled = true,
  debug = false,
  languages = {},
  disabled_languages = {},
  highlight_headers = true,
  debounce_ms = 50,
  max_lines_per_hunk = 500,
})
```

| Option               | Default | Description                                   |
| -------------------- | ------- | --------------------------------------------- |
| `enabled`            | `true`  | Enable/disable highlighting                   |
| `debug`              | `false` | Log debug messages to `:messages`             |
| `languages`          | `{}`    | Custom filename → language mappings           |
| `disabled_languages` | `{}`    | Languages to skip (e.g., `{"markdown"}`)      |
| `highlight_headers`  | `true`  | Highlight context in `@@ ... @@` hunk headers |
| `debounce_ms`        | `50`    | Debounce delay for re-highlighting            |
| `max_lines_per_hunk` | `500`   | Skip treesitter for large hunks               |

## Documentation

```vim
:help fugitive-ts.nvim
```

## Similar Projects

- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- [diffview.nvim](https://github.com/sindrets/diffview.nvim)
