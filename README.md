# diffs.nvim

**Syntax highlighting for diffs in Neovim**

Enhance [vim-fugitive](https://github.com/tpope/vim-fugitive), [Neogit](https://github.com/NeogitOrg/neogit), and
Neovim's built-in diff mode with language-aware syntax highlighting.

<video src="https://github.com/user-attachments/assets/24574916-ecb2-478e-a0ea-e4cdc971e310" width="100%" controls></video>

## Features

- Treesitter syntax highlighting in vim-fugitive, Neogit, and `diff` filetype
- Character-level intra-line diff highlighting (with optional
  [vscode-diff](https://github.com/esmuellert/codediff.nvim) FFI backend for
  word-level accuracy)
- `:Gdiff` unified diff against any revision
- Background-only diff colors for `&diff` buffers
- Inline merge conflict detection, highlighting, and resolution
- Vim syntax fallback, configurable blend/priorities

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

## FAQ

**Does diffs.nvim support vim-fugitive/Neogit?**

Yes. Enable it in your config:

```lua
vim.g.diffs = {
  fugitive = true,
  neogit = true,
}
```

See the documentation for more information.

## Known Limitations

- **Incomplete syntax context**: Treesitter parses each diff hunk in isolation.
  Context lines within the hunk provide syntactic context for the parser. In
  rare cases, hunks that start or end mid-expression may produce imperfect
  highlights due to treesitter error recovery.

- **Syntax "flashing"**: `diffs.nvim` hooks into the `FileType fugitive` event
  triggered by `vim-fugitive`, at which point the buffer is preliminarily
  painted. The decoration provider applies highlights on the next redraw cycle,
  causing a brief visual "flash".

- **Cold Start**: Treesitter grammar loading (~10ms) and query compilation
  (~4ms) are one-time costs per language per Neovim session. Each language pays
  this cost on first encounter, which may cause a brief stutter when a diff
  containing a new language first enters the viewport.

- **Vim syntax fallback is deferred**: The vim syntax fallback (for languages
  without a treesitter parser) cannot run inside the decoration provider's
  redraw cycle due to Neovim's restriction on buffer mutations. Vim syntax
  highlights for these hunks appear slightly delayed.

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
  filetype fix, shebang/modeline detection, treesitter injection support,
  decoration provider highlighting architecture
