# diffs.nvim

**Syntax highlighting for diffs in Neovim**

Enhance vim-fugitive and Neovim's built-in diff mode with language-aware syntax
highlighting.

![diffs.nvim preview](https://github.com/user-attachments/assets/d3d64c96-b824-4fcb-af7f-4aef3f7f498a)

## Features

- Treesitter syntax highlighting in `:Git` diffs and commit views
- `:Gdiffsplit` / `:Gvdiffsplit` syntax through diff backgrounds
- Background-only diff colors for any `&diff` buffer (`:diffthis`, `vimdiff`)
- Vim syntax fallback for languages without a treesitter parser
- Hunk header context highlighting (`@@ ... @@ function foo()`)
- Configurable debouncing, max lines, and diff prefix concealment

## Requirements

- Neovim 0.9.0+
- [vim-fugitive](https://github.com/tpope/vim-fugitive) (optional, for unified
  diff syntax highlighting)

## Installation

Install with your package manager of choice or via
[luarocks](https://luarocks.org/modules/barrettruth/diffs.nvim):

```
luarocks install diffs.nvim
```

## Documentation

```vim
:help diffs.nvim
```

## Known Limitations

- Syntax "flashing": diffs.nvim hooks into the `FileType fugitive` event
  triggered by vim-fugitive, at which point the buffer is preliminarily painted.
  The buffer is then re-painted after `debounce_ms` milliseconds, causing an
  unavoidable visual "flash" even when `debounce_ms = 0`.

# Acknowledgements

- [vim-fugitive](https://github.com/tpope/vim-fugitive)
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- [diffview.nvim](https://github.com/sindrets/diffview.nvim)
