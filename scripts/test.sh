#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

if command -v luarocks &> /dev/null; then
  luarocks test --local
else
  echo "luarocks not found, running nvim directly..."
  nvim --headless --noplugin \
    -u spec/minimal_init.lua \
    -c "lua require('busted.runner')({ standalone = false })" \
    -c "qa!"
fi
