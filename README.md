# diffs.nvim

**Syntax highlighting for diffs in Neovim**

Enhance vim-fugitive and Neovim's built-in diff mode with language-aware syntax
highlighting.

![diffs.nvim preview](https://github.com/user-attachments/assets/fc849310-09c8-4282-8a92-a2edaf8fe2b4)

## Features

- Treesitter syntax highlighting in `:Git` diffs and commit views
- `:Gdiffsplit` / `:Gvdiffsplit` syntax through diff backgrounds
- Background-only diff colors for any `&diff` buffer
- Vim syntax fallback for languages without a treesitter parser
- Hunk header context highlighting (`@@ ... @@ function foo()`)
- Configurable debouncing, max lines, and diff prefix concealment

## Requirements

- Neovim 0.9.0+
- [vim-fugitive](https://github.com/tpope/vim-fugitive)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'barrettruth/diffs.nvim',
  dependencies = { 'tpope/vim-fugitive' },
  opts = {},
}
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

## Acknowledgements

- [vim-fugitive](https://github.com/tpope/vim-fugitive)
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- [diffview.nvim](https://github.com/sindrets/diffview.nvim)
