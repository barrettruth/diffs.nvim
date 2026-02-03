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

## Highlight Groups

diffs.nvim defines the following highlight groups. All use `default = true`, so
colorschemes can override them.

| Group             | Purpose                                            |
| ----------------- | -------------------------------------------------- |
| `DiffsAdd`        | Background for `+` lines in fugitive unified diffs |
| `DiffsDelete`     | Background for `-` lines in fugitive unified diffs |
| `DiffsAddNr`      | Line number highlight for `+` lines                |
| `DiffsDeleteNr`   | Line number highlight for `-` lines                |
| `DiffsDiffAdd`    | Background-only `DiffAdd` for `&diff` windows      |
| `DiffsDiffDelete` | Background-only `DiffDelete` for `&diff` windows   |
| `DiffsDiffChange` | Background-only `DiffChange` for `&diff` windows   |
| `DiffsDiffText`   | Background-only `DiffText` for `&diff` windows     |

By default, these are computed from your colorscheme's `DiffAdd`, `DiffDelete`,
`DiffChange`, `DiffText`, and `Normal` groups. To customize, define them in your
colorscheme before diffs.nvim loads, or link them to existing groups.

## Known Limitations

- Syntax "flashing": diffs.nvim hooks into the `FileType fugitive` event
  triggered by vim-fugitive, at which point the buffer is preliminarily painted.
  The buffer is then re-painted after `debounce_ms` milliseconds, causing an
  unavoidable visual "flash" even when `debounce_ms = 0`.

## Acknowledgements

- [vim-fugitive](https://github.com/tpope/vim-fugitive)
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- [diffview.nvim](https://github.com/sindrets/diffview.nvim)
