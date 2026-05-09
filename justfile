default:
    @just --list

format:
    nix fmt -- --ci
    stylua --check .
    biome format .

commitlint range="origin/main..HEAD":
    scripts/check-commit-subject --range "{{range}}"

install-hooks:
    git config core.hooksPath .githooks

lint:
    git ls-files '*.lua' | xargs selene --display-style quiet
    lua-language-server --check lua --configpath "$(pwd)/.luarc.json" --checklevel=Warning
    vimdoc-language-server check doc/

test:
    busted

ci: commitlint format lint test
    @:
