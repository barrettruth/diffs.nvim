# fugitive-ts.nvim

**Treesitter syntax highlighting for vim-fugitive**

Enhance the great `vim-fugitive` with syntax-aware code to easily work with
diffs.

![fugitive-ts.nvim preview](https://github.com/user-attachments/assets/90463492-76e4-44c2-a095-057a087c3a36)

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

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'barrettruth/fugitive-ts.nvim',
  dependencies = { 'tpope/vim-fugitive' },
  opts = {},
}
```

## Documentation

```vim
:help fugitive-ts.nvim
```

## Known Limitations

- Syntax "flashing": `fugitive-ts.nvim` hooks into the `FileType fugitive` event
  triggered by `vim-fugitive`, at which point the `fugitive` buffer is
  preliminarily painted. The buffer is then re-painted after `debounce_ms`
  milliseconds, causing an unavoidable visual "flash" even when
  `debounce_ms = 0`. Feel free to reach out if you know how to fix this!

## Acknowledgements

- [vim-fugitive](https://github.com/tpope/vim-fugitive)
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- [diffview.nvim](https://github.com/sindrets/diffview.nvim)
- [resolve.nvim](https://github.com/spacedentist/resolve.nvim)
