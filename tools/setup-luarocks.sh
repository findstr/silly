#!/usr/bin/env bash
# Setup luarocks and luacov for Silly testing
# Usage: tools/setup-luarocks.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Detect Lua version from deps/lua
if [ ! -f "$PROJECT_ROOT/deps/lua/lua" ]; then
    echo -e "${RED}Error: deps/lua/lua not found${NC}"
    echo "Please build the project first: make test"
    exit 1
fi

LUA_VERSION=$("$PROJECT_ROOT/deps/lua/lua" -e "v=_VERSION:match('Lua (%d+.%d+)'); print(v)" 2>/dev/null)
if [ -z "$LUA_VERSION" ]; then
    echo -e "${RED}Error: Failed to detect Lua version${NC}"
    exit 1
fi

echo "🔍 Detected Lua version: $LUA_VERSION"
echo "$LUA_VERSION"  # Output version for caller to capture

# Setup luarocks
LUAROCKS_VERSION="3.13.0"
LUAROCKS_BIN="$SCRIPT_DIR/luarocks/luarocks"
LUAROCKS_ZIP="$SCRIPT_DIR/luarocks-${LUAROCKS_VERSION}-linux-x86_64.zip"

if [ ! -f "$LUAROCKS_BIN" ]; then
    echo "📦 Installing luarocks $LUAROCKS_VERSION..."

    # Download if not exists
    if [ ! -f "$LUAROCKS_ZIP" ]; then
        echo "  Downloading..."
        wget -q --show-progress -O "$LUAROCKS_ZIP" \
            "https://luarocks.github.io/luarocks/releases/luarocks-${LUAROCKS_VERSION}-linux-x86_64.zip"
    fi

    # Extract
    echo "  Extracting..."
    mkdir -p "$SCRIPT_DIR/luarocks"
    unzip -q -j -o "$LUAROCKS_ZIP" \
        "luarocks-${LUAROCKS_VERSION}-linux-x86_64/luarocks" \
        "luarocks-${LUAROCKS_VERSION}-linux-x86_64/luarocks-admin" \
        -d "$SCRIPT_DIR/luarocks/"

    chmod +x "$LUAROCKS_BIN"
    echo -e "${GREEN}✅ luarocks installed${NC}"
else
    echo "✅ luarocks already installed"
fi

# Configure luarocks for project's Lua
echo "⚙️  Configuring luarocks for Lua $LUA_VERSION..."

# Test 1: Check if luarocks can run
if ! "$LUAROCKS_BIN" --version >/dev/null 2>&1; then
    echo -e "${RED}Error: luarocks executable failed${NC}"
    exit 1
fi
echo "  ✓ luarocks executable OK"

# Test 2: Check if luarocks can access deps/lua
if [ ! -d "$PROJECT_ROOT/deps/lua" ]; then
    echo -e "${RED}Error: deps/lua directory not found${NC}"
    exit 1
fi
echo "  ✓ deps/lua directory OK"

# Configure luarocks
"$LUAROCKS_BIN" config --scope=user variables.LUA_INCDIR "$PROJECT_ROOT/deps/lua" >/dev/null 2>&1 || true

# Check and install luacov
LUACOV_TEST="$("$PROJECT_ROOT/deps/lua/lua" -e "
    package.path='$PROJECT_ROOT/.lua_modules/share/lua/$LUA_VERSION/?.lua;' .. package.path
    local ok, _ = pcall(require, 'luacov')
    print(ok and '1' or '0')
" 2>/dev/null)"

if [ "$LUACOV_TEST" = "1" ]; then
    echo "✅ luacov already installed and functional"
else
    echo "📦 Installing luacov for Lua $LUA_VERSION..."
    if LUA_INCDIR="$PROJECT_ROOT/deps/lua" \
       LUA_LIBDIR="$PROJECT_ROOT/deps/lua" \
       "$LUAROCKS_BIN" \
       --tree "$PROJECT_ROOT/.lua_modules" \
       --lua-dir="$PROJECT_ROOT/deps/lua" \
       --lua-version="$LUA_VERSION" \
       install luacov >/dev/null 2>&1; then
        echo -e "${GREEN}✅ luacov installed${NC}"
    else
        echo -e "${RED}❌ luacov installation failed${NC}"
        exit 1
    fi
fi

# Check and install luacov-reporter-lcov
LUACOV_LCOV_TEST="$("$PROJECT_ROOT/deps/lua/lua" -e "
    package.path='$PROJECT_ROOT/.lua_modules/share/lua/$LUA_VERSION/?.lua;' .. package.path
    local ok, _ = pcall(require, 'luacov.reporter.lcov')
    print(ok and '1' or '0')
" 2>/dev/null)"

if [ "$LUACOV_LCOV_TEST" = "1" ]; then
    echo "✅ luacov-reporter-lcov already installed and functional"
else
    echo "📦 Installing luacov-reporter-lcov for Lua $LUA_VERSION..."
    if LUA_INCDIR="$PROJECT_ROOT/deps/lua" \
       LUA_LIBDIR="$PROJECT_ROOT/deps/lua" \
       "$LUAROCKS_BIN" \
       --tree "$PROJECT_ROOT/.lua_modules" \
       --lua-dir="$PROJECT_ROOT/deps/lua" \
       --lua-version="$LUA_VERSION" \
       install luacov-reporter-lcov >/dev/null 2>&1; then
        echo -e "${GREEN}✅ luacov-reporter-lcov installed${NC}"
    else
        echo -e "${RED}❌ luacov-reporter-lcov installation failed${NC}"
        exit 1
    fi
fi

# Verify installation
echo "🔍 Verifying installations..."
LUACOV_TEST_AFTER="$("$PROJECT_ROOT/deps/lua/lua" -e "
    package.path='$PROJECT_ROOT/.lua_modules/share/lua/$LUA_VERSION/?.lua;' .. package.path
    local ok1, _ = pcall(require, 'luacov')
    local ok2, _ = pcall(require, 'luacov.reporter.lcov')
    print((ok1 and ok2) and '1' or '0')
" 2>/dev/null)"

if [ "$LUACOV_TEST_AFTER" = "1" ]; then
    echo -e "${GREEN}✅ luacov and luacov-reporter-lcov installed and verified${NC}"
    exit 0
else
    echo -e "${YELLOW}⚠️  Modules installed but failed verification${NC}"
    exit 1
fi
