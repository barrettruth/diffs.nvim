# diffs.nvim

Language syntax highlighting for unified diffs in Neovim.

Diffs uses Treesitter or Vim syntax to highlight the code inside diff hunks.
It adds line backgrounds and intra-line highlights, and adjusts colors in native
diff windows.

<img width="863" height="752" alt="image" src="https://github.com/user-attachments/assets/fb67f1f5-e64b-4b67-88f4-2d8d37d9f9f2" />

## Requirements

- Neovim 0.12.0+
- Optional: Treesitter parsers for the languages in your diffs and the `diff` parser

## Installation

```lua
vim.pack.add({ 'https://github.com/barrettruth/diffs.nvim' })
```

Diffs attaches to `git` and `gitcommit` buffers by default. Enable integrations
before the plugin loads:

```lua
vim.g.diffs = {
  integrations = { 'fugitive', 'neogit', 'neojj', 'gitsigns', 'committia', 'telescope' },
}
```

To highlight patch files with the `diff` filetype:

```lua
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'diff',
  callback = function(event)
    require('diffs').attach(event.buf)
  end,
})
```

Use `'diffopt'` to select intra-line highlighting:

```vim
set diffopt+=inline:word
```

See `:help diffs.nvim` for configuration and the Lua API. Run `:checkhealth diffs`
for dependency information.

## Diff commands and conflicts

[diffs-collection.nvim](https://github.com/barrettruth/diffs-collection.nvim)
contains file comparison, repository review, split views, quickfix navigation,
and conflict resolution. Install it alongside diffs.nvim for these workflows.

## Limitations

Treesitter parses each hunk separately. Hunks that start or end inside an
expression can have incomplete syntax highlighting.

Vim syntax fallback runs after redraw. A new hunk can appear without syntax
colors for one frame. Language parsers and queries also load on first use.

Other plugins that change diff highlights can produce conflicting colors.

## Acknowledgements

- [vim-fugitive](https://github.com/tpope/vim-fugitive)
- [diffview.nvim](https://github.com/sindrets/diffview.nvim)
- [difftastic](https://github.com/Wilfred/difftastic)
- [mini.diff](https://github.com/echasnovski/mini.diff)
- [gitsigns.nvim](https://github.com/lewis6991/gitsigns.nvim)
- [git-conflict.nvim](https://github.com/akinsho/git-conflict.nvim)
- [@phanen](https://github.com/phanen) — header highlighting, filetype detection,
  Treesitter injections, decoration providers, Gitsigns popups, and intra-line colors
- [@tris203](https://github.com/tris203) — transparent backgrounds
- [@letientai299](https://github.com/letientai299) — `diff.mnemonicPrefix` support
