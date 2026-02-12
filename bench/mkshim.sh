#!/usr/bin/env bash
set -euo pipefail

COMMITS=${1:-50}
DIR=${2:-/tmp/diffs-bench-scale}

rm -rf "$DIR"
mkdir -p "$DIR"
git -C "$DIR" init -q
git -C "$DIR" config commit.gpgSign false

files=(
  app.lua lib.rs server.py main.go index.ts engine.c
  Service.java middleware.rb parser.zig schema.sql
  build.sh config.tcl deploy.groovy solver.pl types.hs
  analysis.R legacy.cob Makefile App.jsx style.css
)

contents_lua='local M = {}\nfunction M.setup()\n  return true\nend\nreturn M'
contents_rs='fn main() {\n    let x = 42;\n    println!("{}", x);\n}'
contents_py='def main():\n    x = 42\n    print(x)\n\nif __name__ == "__main__":\n    main()'
contents_go='package main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Println("hello")\n}'
contents_ts='export function greet(name: string): string {\n  return `hello ${name}`;\n}'
contents_c='#include <stdio.h>\nint main() {\n    printf("hello\\n");\n    return 0;\n}'
contents_java='public class Service {\n    public void run() {\n        System.out.println("ok");\n    }\n}'
contents_rb='class Middleware\n  def call(env)\n    [200, {}, ["ok"]]\n  end\nend'
contents_zig='const std = @import("std");\npub fn main() !void {\n    std.debug.print("hello\\n", .{});\n}'
contents_sql='CREATE TABLE users (\n  id INTEGER PRIMARY KEY,\n  name TEXT NOT NULL\n);'
contents_sh='#!/bin/bash\nset -e\necho "building..."'
contents_generic='line 1\nline 2\nline 3\nline 4'

for f in "${files[@]}"; do
  case "$f" in
    *.lua) printf '%b' "$contents_lua" > "$DIR/$f" ;;
    *.rs)  printf '%b' "$contents_rs" > "$DIR/$f" ;;
    *.py)  printf '%b' "$contents_py" > "$DIR/$f" ;;
    *.go)  printf '%b' "$contents_go" > "$DIR/$f" ;;
    *.ts|*.tsx|*.jsx) printf '%b' "$contents_ts" > "$DIR/$f" ;;
    *.c)   printf '%b' "$contents_c" > "$DIR/$f" ;;
    *.java) printf '%b' "$contents_java" > "$DIR/$f" ;;
    *.rb)  printf '%b' "$contents_rb" > "$DIR/$f" ;;
    *.zig) printf '%b' "$contents_zig" > "$DIR/$f" ;;
    *.sql) printf '%b' "$contents_sql" > "$DIR/$f" ;;
    *.sh)  printf '%b' "$contents_sh" > "$DIR/$f" ;;
    *)     printf '%b' "$contents_generic" > "$DIR/$f" ;;
  esac
done

git -C "$DIR" add -A
git -C "$DIR" commit -q -m "initial"

for i in $(seq 1 "$COMMITS"); do
  idx=$(( (i - 1) % ${#files[@]} ))
  f="${files[$idx]}"
  echo "-- commit $i change" >> "$DIR/$f"
  git -C "$DIR" add "$f"
  git -C "$DIR" commit -q -m "change $i to $f"
done

echo "created $DIR with $COMMITS commits ($(git -C "$DIR" log -p --no-color | wc -l) diff lines)"
