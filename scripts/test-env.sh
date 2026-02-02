#!/usr/bin/env bash
set -e

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR=$(mktemp -d)

echo "Creating test environment in $TEMP_DIR"

cd "$TEMP_DIR"
git init -q

cat > test.lua << 'EOF'
local M = {}

function M.hello()
  local msg = "hello world"
  print(msg)
  return true
end

return M
EOF

cat > test.py << 'EOF'
def hello():
    msg = "hello world"
    print(msg)
    return True

if __name__ == "__main__":
    hello()
EOF

cat > test.js << 'EOF'
function hello() {
  const msg = "hello world";
  console.log(msg);
  return true;
}

module.exports = { hello };
EOF

git add -A
git commit -q -m "initial commit"

cat >> test.lua << 'EOF'

function M.goodbye()
  local msg = "goodbye world"
  print(msg)
  return false
end
EOF

cat >> test.py << 'EOF'

def goodbye():
    msg = "goodbye world"
    print(msg)
    return False
EOF

cat >> test.js << 'EOF'

function goodbye() {
  const msg = "goodbye world";
  console.log(msg);
  return false;
}
EOF

git add test.lua

cat > init.lua << EOF
vim.opt.rtp:prepend('$PLUGIN_DIR')
vim.opt.rtp:prepend(vim.fn.stdpath('data') .. '/lazy/vim-fugitive')

require('fugitive-ts').setup({
  debug = true,
})

vim.cmd('Git')
EOF

echo "Test repo created with:"
echo "  - test.lua (staged changes)"
echo "  - test.py (unstaged changes)"
echo "  - test.js (unstaged changes)"
echo ""
echo "Opening neovim with fugitive..."

nvim -u init.lua
