# diffs.nvim

**Syntax highlighting for diffs in Neovim**

Enhance `vim-fugitive` and Neovim's built-in diff mode with language-aware
syntax highlighting.

![diffs.nvim preview](https://github.com/user-attachments/assets/d3d64c96-b824-4fcb-af7f-4aef3f7f498a)

## Features

- Treesitter syntax highlighting in `:Git` diffs and commit views
- Diff header highlighting (`diff --git`, `index`, `---`, `+++`)
- `:Gdiffsplit` / `:Gvdiffsplit` syntax through diff backgrounds
- `:Gdiff` unified diff against any git revision with syntax highlighting
- Fugitive status buffer keymaps (`du`/`dU`) for unified diffs
- Background-only diff colors for any `&diff` buffer (`:diffthis`, `vimdiff`)
- Vim syntax fallback for languages without a treesitter parser
- Hunk header context highlighting (`@@ ... @@ function foo()`)
- Character-level (intra-line) diff highlighting for changed characters
- Configurable debouncing, max lines, and diff prefix concealment

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

- **Incomplete syntax context**: Treesitter parses each diff hunk in isolation
  without surrounding code context. When a hunk shows lines added to an existing
  block (e.g., adding a plugin inside `return { ... }`), the parser doesn't see
  the `return` statement and may produce incorrect highlighting. This is
  inherent to parsing code fragments—no diff tooling solves this without
  significant complexity.

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
    conflict marker highlighting may overlap with `diffs.nvim`

# Acknowledgements

- [`vim-fugitive`](https://github.com/tpope/vim-fugitive)
- [`codediff.nvim`](https://github.com/esmuellert/codediff.nvim)
- [`diffview.nvim`](https://github.com/sindrets/diffview.nvim)
- [`difftastic`](https://github.com/Wilfred/difftastic)
- [`mini.diff`](https://github.com/echasnovski/mini.diff)
- [`gitsigns.nvim`](https://github.com/lewis6991/gitsigns.nvim)
- [`git-conflict.nvim`](https://github.com/akinsho/git-conflict.nvim)
- [@phanen](https://github.com/phanen) - diff header highlighting, unknown
  filetype fix, shebang/modeline detection
