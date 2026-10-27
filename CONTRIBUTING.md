# Contributing

Development happens on
[GitHub](https://github.com/barrettruth/diffs.nvim). Open
[pull requests](https://github.com/barrettruth/diffs.nvim/pulls) for patches
and report bugs on the
[issue tracker](https://github.com/barrettruth/diffs.nvim/issues).

## Patches

Bug fixes and documentation fixes are welcome. AI-generated contributions are
not accepted.

For new behavior, open a ticket first unless the change is small and already
fits the project's scope.

Behavior or configuration changes should update `README.md` and
`doc/diffs.nvim.txt` when appropriate.

## Development

It is preferred to use the Nix development shell, which bundles all necessary
tools:

```sh
nix develop
```

## Checks

Run the local checks before sending a patch:

```sh
nix develop --command just ci
```
