#!/usr/bin/env sh
# Usage: sh test.sh [extra args]

set -eu

# ---- Detect platform ----
uname_S=$(sh -c 'uname -s 2>/dev/null || echo not')
uname_M=$(sh -c 'uname -m 2>/dev/null || echo not')

case "$uname_S" in
    Linux)
        PLATFORM=linux
        ;;
    Darwin)
        PLATFORM=darwin
        ;;
    *_NT*|MINGW*|MSYS*)
        PLATFORM=mingw
        ;;
    *)
        PLATFORM=unknown
        ;;
esac

# ---- Platform-specific ARGS ----
ARGS=""
case "$PLATFORM" in
    linux)
        ARGS="--test.timer.checkdelta=500 --test.grpc.timeout=5000"
        ;;
    darwin)
        ARGS="--test.timer.checkdelta=1000 --test.grpc.timeout=10000"
        ;;
    mingw)
        ARGS="--test.timer.checkdelta=1000 --test.grpc.timeout=10000"
        ;;
    *)
        echo "⚠️  Unknown platform: $uname_S ($uname_M)"
        exit 1
        ;;
esac

# Merge extra arguments from command line
if [ $# -gt 0 ]; then
    ARGS="$ARGS $*"
fi

# ---- Locate test files ----
TEST_DIR="test"
SILLY="./silly"
TEST_SCRIPT="test/test.lua"

if [ ! -x "$SILLY" ]; then
    echo "❌ Error: Executable $SILLY not found"
    exit 1
fi

echo "🧪 Platform: $PLATFORM"
echo "🧰 Test arguments: $ARGS"
echo "📂 Scanning test directory: $TEST_DIR"

# POSIX-compatible sorting (works on macOS / Linux)
TEST_FILES=$(find "$TEST_DIR" -maxdepth 1 -type f -name '*.lua' ! -name 'test.lua' ! -name 'testprometheus.lua' | sort)
if [ -z "$TEST_FILES" ]; then
    echo "⚠️  No test files (*.lua) found"
    exit 1
fi

# ---- Run tests ----
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

for file in $TEST_FILES; do
    base=$(basename "$file" .lua)

    # Skip certain tests on non-Linux platforms
    if [ "$PLATFORM" != "linux" ] && { [ "$base" = "testmysql" ] || [ "$base" = "testredis" ]; }; then
        echo "⏭️  Skipping test: $base (only runs on Linux)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    echo "🔹 Running test: $base"
    $SILLY "$TEST_SCRIPT" --case="$base" $ARGS
    rc=$?
    TOTAL=$((TOTAL + 1))
    if [ $rc -eq 0 ]; then
        echo "✅ Passed: $base"
        PASSED=$((PASSED + 1))
    else
        echo "❌ Failed: $base (exit code=$rc)"
        FAILED=$((FAILED + 1))
        echo "🛑 Stopping on first failure"
        exit $rc
    fi
done

echo "🎉 All tests passed: $PASSED/$TOTAL (skipped: $SKIPPED)"
exit 0
