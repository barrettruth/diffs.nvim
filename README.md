# diffs.nvim

**Treesitter-powered Diff Syntax highlighting for Neovim**

Enhance Neovim's built-in diff mode (and much more!) with language-aware syntax
highlighting driven by treesitter.

<video src="https://github.com/user-attachments/assets/24574916-ecb2-478e-a0ea-e4cdc971e310" width="100%" controls></video>

## Features

- Treesitter syntax highlighting in
  [vim-fugitive](https://github.com/tpope/vim-fugitive),
  [Neogit](https://github.com/NeogitOrg/neogit), builtin `diff` filetype, and
  more!
- Character-level intra-line diff highlighting
- Word-level diff highlighting
- `:Gdiff` unified diff against any revision
- `:Greview` full-repo review diff with qflist/loclist navigation
- Inline merge conflict detection, highlighting, and resolution
- Email quoting/patch syntax support (`> diff ...`)
- Vim syntax fallback
- Configurable highlighting blend & priorities

## Requirements

- Neovim 0.9.0+
- Optional: the Treesitter `diff` parser for the best experience

## Installation

With `vim.pack` (Neovim 0.12+):

```lua
vim.pack.add({
  'https://git.barrettruth.com/barrettruth/diffs.nvim',
})
```

Or via [luarocks](https://luarocks.org/modules/barrettruth/diffs.nvim):

```
luarocks install diffs.nvim
```

## Documentation

```vim
:help diffs.nvim
```

## Generated `:Gdiff`

`:Gdiff` opens a generated unified `diffs://` buffer, not native Fugitive
`:Gdiffsplit` windows. Plain `:Gdiff` from a worktree file shows the
index-to-worktree edge, so staged-only changes report no unstaged changes. In a
Fugitive status buffer, `du`/`dU` choose the edge from the row: staged rows show
`HEAD -> index`, unstaged rows show `index -> worktree`, untracked rows show an
all-added file, and unmerged rows show ours `:2:` vs theirs `:3:`.

Generated hunk actions are capability-scoped: `dp` stages supported
index-to-worktree hunks/ranges, and `do` unstages supported tree-to-index
hunks/ranges. Native `:Gdiffsplit!`, 3-way `&diff` windows, writable Fugitive
object buffers, and `dq` are outside this generated-buffer contract.

## FAQ

**Q: Does diffs.nvim support
[vim-fugitive](https://github.com/tpope/vim-fugitive)/[Neogit](https://github.com/NeogitOrg/neogit)/[neojj](https://github.com/NicholasZolton/neojj)/[gitsigns](https://github.com/lewis6991/gitsigns.nvim)/[fzf-lua](https://github.com/ibhagwan/fzf-lua)?**

Yes. Enable integrations in your config:

```lua
vim.g.diffs = {
  integrations = {
    fugitive = true,
    neogit = true,
    neojj = true,
    gitsigns = true,
  }
}
```

fzf-lua is supported out-of-the-box.

See the documentation for more information.

## Known Limitations

- **Incomplete syntax context**: Treesitter parses each diff hunk in isolation.
  Context lines within the hunk provide syntactic context for the parser. In
  rare cases, hunks that start or end mid-expression may produce imperfect
  highlights due to treesitter error recovery.

- **Syntax "flashing"**: `diffs.nvim` hooks into the `FileType fugitive` event
  triggered by `vim-fugitive`, at which point the buffer is preliminarily
  painted. The decoration provider applies highlights on the next redraw cycle,
  so a brief first-paint flash may still occur.

- **Cold Start**: Treesitter grammar loading (~10ms) and query compilation
  (~4ms) are one-time costs per language per Neovim session. Each language pays
  this cost on first encounter, which may cause a brief stutter when a diff
  containing a new language first enters the viewport.

- **Vim syntax fallback is deferred**: The vim syntax fallback (for languages
  without a treesitter parser) cannot run inside the decoration provider's
  redraw cycle due to Neovim's restriction on buffer mutations. Vim syntax
  highlights for cold hunks may appear one frame later. Warm hunks can reuse
  cached vim syntax spans, and stale deferred renders are ignored after buffer
  changes.

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
  decoration provider highlighting architecture, gitsigns blame popup
  highlighting, intra-line bg visibility fix
- [@tris203](https://github.com/tris203) - support for transparent backgrounds
- [@letientai299](https://github.com/letientai299) - `diff.mnemonicPrefix`
  support
