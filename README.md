# diffs.nvim

**Syntax highlighting for diffs in Neovim**

Enhance `vim-fugitive` and Neovim's built-in diff mode with language-aware
syntax highlighting.

![diffs.nvim preview](https://github.com/user-attachments/assets/d3d64c96-b824-4fcb-af7f-4aef3f7f498a)

## Features

- Treesitter syntax highlighting in fugitive diffs and commit views
- Word-level intra-line diff highlighting, including VSCode's diffing algorithm
- `:Gdiff` unified diff against any revision
- Background-only diff colors for `&diff` buffers
- Inline merge conflict detection, highlighting, and resolution
- Vim syntax fallback, configurable blend/debounce/priorities

## Requirements

- Neovim 0.9.0+

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

- **Incomplete syntax context**: Treesitter parses each diff hunk in isolation.
  Context lines within the hunk (` ` prefix) provide syntactic context for the
  parser. In rare cases, hunks that start or end mid-expression may produce
  imperfect highlights due to treesitter error recovery.

- **Syntax flashing**: `diffs.nvim` hooks into the `FileType fugitive` event
  triggered by `vim-fugitive`, at which point the buffer is preliminarily
  painted. The buffer is then re-painted after `debounce_ms` milliseconds,
  causing an unavoidable visual "flash" even when `debounce_ms = 0`.

- **Conflicting diff plugins**: `diffs.nvim` may not interact well with other
  plugins that modify diff highlighting. Known plugins that may conflict:
  - [`diffview.nvim`](https://github.com/sindrets/diffview.nvim) - provides its
    own diff highlighting and conflict resolution UI
  - [`mini.diff`](https://github.com/echasnovski/mini.diff) - visualizes buffer
    differences with its own highlighting system
  - [`gitsigns.nvim`](https://github.com/lewis6991/gitsigns.nvim) - generally
    compatible, but both plugins modifying line highlights may produce
    unexpected results
  - [`git-conflict.nvim`](https://github.com/akinsho/git-conflict.nvim) -
    `diffs.nvim` now includes built-in conflict resolution; disable one or the
    other to avoid overlap

# Acknowledgements

- [`vim-fugitive`](https://github.com/tpope/vim-fugitive)
- [@esmuellert](https://github.com/esmuellert) /
  [`codediff.nvim`](https://github.com/esmuellert/codediff.nvim) - vscode-diff
  algorithm FFI backend for word-level intra-line accuracy
- [`diffview.nvim`](https://github.com/sindrets/diffview.nvim)
- [`difftastic`](https://github.com/Wilfred/difftastic)
- [`mini.diff`](https://github.com/echasnovski/mini.diff)
- [`gitsigns.nvim`](https://github.com/lewis6991/gitsigns.nvim)
- [`git-conflict.nvim`](https://github.com/akinsho/git-conflict.nvim)
- [@phanen](https://github.com/phanen) - diff header highlighting, unknown
  filetype fix, shebang/modeline detection, treesitter injection support
