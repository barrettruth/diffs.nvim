#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

run_job() {
  local name=$1
  shift
  local log="$tmpdir/$name.log"
  if "$@" >"$log" 2>&1; then
    echo -e "${GREEN}✓${RESET} $name"
    return 0
  else
    echo -e "${RED}✗${RESET} $name"
    cat "$log"
    return 1
  fi
}

echo -e "${BOLD}Running CI jobs in parallel...${RESET}"
echo

pids=()
jobs_names=()

run_job "stylua" stylua --check . &
pids+=($!); jobs_names+=("stylua")

run_job "selene" selene --display-style quiet . &
pids+=($!); jobs_names+=("selene")

run_job "prettier" prettier --check . &
pids+=($!); jobs_names+=("prettier")

run_job "busted" env \
  LUA_PATH="/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;/usr/lib/lua/5.1/?.lua;/usr/lib/lua/5.1/?/init.lua;;" \
  LUA_CPATH="/usr/lib/lua/5.1/?.so;;" \
  nvim -l /usr/lib/luarocks/rocks-5.1/busted/2.3.0-1/bin/busted --verbose spec/ &
pids+=($!); jobs_names+=("busted")

failed=0
for i in "${!pids[@]}"; do
  if ! wait "${pids[$i]}"; then
    failed=1
  fi
done

echo
if [ "$failed" -eq 0 ]; then
  echo -e "${GREEN}${BOLD}All jobs passed.${RESET}"
else
  echo -e "${RED}${BOLD}Some jobs failed.${RESET}"
  exit 1
fi
