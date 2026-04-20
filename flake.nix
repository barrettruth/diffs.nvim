{
  description = "diffs.nvim — syntax highlighting for diffs in Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      nixpkgs,
      systems,
      ...
    }:
    let
      forEachSystem =
        f: nixpkgs.lib.genAttrs (import systems) (system: f nixpkgs.legacyPackages.${system});
    in
    {
      formatter = forEachSystem (pkgs: pkgs.nixfmt-tree);

      devShells = forEachSystem (
        pkgs:
        let
          ts-plugin = pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [ p.diff ]);
          diff-grammar = pkgs.vimPlugins.nvim-treesitter-parsers.diff;
          luaEnv = pkgs.luajit.withPackages (
            ps: with ps; [
              busted
              nlua
            ]
          );
          busted-with-grammar = pkgs.writeShellScriptBin "busted" ''
            nvim_bin=$(which nvim)
            tmpdir=$(mktemp -d)
            trap 'rm -rf "$tmpdir"' EXIT
            printf '#!/bin/sh\nexec "%s" --cmd "set rtp+=${ts-plugin}/runtime" --cmd "set rtp+=${diff-grammar}" "$@"\n' "$nvim_bin" > "$tmpdir/nvim"
            chmod +x "$tmpdir/nvim"
            PATH="$tmpdir:$PATH" exec ${luaEnv}/bin/busted "$@"
          '';
          vimdoc-ls = pkgs.vimdoc-language-server;
          commonPackages = [
            busted-with-grammar
            pkgs.just
            pkgs.prettier
            pkgs.stylua
            pkgs.selene
            pkgs.lua-language-server
            vimdoc-ls
          ];
        in
        {
          default = pkgs.mkShell {
            packages = commonPackages;
          };
          ci = pkgs.mkShell {
            packages = commonPackages ++ [ pkgs.neovim ];
          };
        }
      );
    };
}
