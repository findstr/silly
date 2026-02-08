#!/usr/bin/env sh
# Usage: sh test.sh [-j|--parallel] [extra args]

set -eu

# Parse parallel flag
PARALLEL_MODE=0
ARGS_LIST=""
OVERRIDE_SET=""
while [ $# -gt 0 ]; do
    case "$1" in
        -j|--parallel)
            PARALLEL_MODE=1
            shift
            ;;
        --set=*)
            OVERRIDE_SET=$(printf "%s" "$1" | sed 's/^--set=//')
            ARGS_LIST="$ARGS_LIST $1"
            shift
            ;;
        --set)
            shift
            OVERRIDE_SET="$1"
            ARGS_LIST="$ARGS_LIST --set=$1"
            shift
            ;;
        *)
            ARGS_LIST="$ARGS_LIST $1"
            shift
            ;;
    esac
done

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

# ---- Sanitizer options (fail fast) ----
if [ -z "${ASAN_OPTIONS+x}" ]; then
    case "$PLATFORM" in
        darwin)
            # LSan is flaky on macOS runners; disable leak detection by default.
            export ASAN_OPTIONS="halt_on_error=1:detect_leaks=0"
            ;;
        *)
            export ASAN_OPTIONS="halt_on_error=1:detect_leaks=1"
            ;;
    esac
else
    export ASAN_OPTIONS
fi
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"
export TSAN_OPTIONS="${TSAN_OPTIONS:-halt_on_error=1:report_signal_unsafe=1}"

# ---- Platform-specific ARGS ----
ARGS=""
case "$PLATFORM" in
    linux)
        ARGS="--test.timer.checkdelta=500 --test.grpc.timeout=10000"
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
if [ -n "$ARGS_LIST" ]; then
    ARGS="$ARGS $ARGS_LIST"
fi

SET_ARG=""
if [ -n "$OVERRIDE_SET" ]; then
    SET_ARG="--set=$OVERRIDE_SET"
fi

# ---- Locate test files ----
TEST_DIR="test"
TEST_SCRIPT="test/test.lua"

# ---- Detect test binaries ----
BINARIES=""
if [ -x "./silly.asan" ] && [ -x "./silly.tsan" ]; then
    BINARIES="./silly.asan ./silly.tsan"
else
    BINARIES="./silly"
fi

for b in $BINARIES; do
    if [ ! -x "$b" ]; then
        echo "❌ Error: Executable $b not found"
        exit 1
    fi
done

# ---- Preflight checks ----
echo "🔍 Preflight: CLI version/help"
for b in $BINARIES; do
    if ! $b --version >/dev/null 2>&1; then
        echo "❌ Preflight failed: $b --version"
        exit 1
    fi
    if ! $b --help >/dev/null 2>&1; then
        echo "❌ Preflight failed: $b --help"
        exit 1
    fi
done

# ---- Test endless loop detection ----
# This test verifies that the monitor thread correctly detects endless loops
# and sends SIGUSR2 to trigger the warning. Only run on Unix platforms.
run_endless_test() {
    if [ "$PLATFORM" = "mingw" ]; then
        echo "⏭️  Skipping endless loop test (not supported on Windows)"
        return 0
    fi
    for b in $BINARIES; do
        cpath="luaclib"
        if [ "$b" = "./silly.asan" ]; then
            cpath="luaclib.asan"
        elif [ "$b" = "./silly.tsan" ]; then
            cpath="luaclib.tsan"
        fi
        export SILLY_LUACLIB_PATH="$cpath"
        export SILLY_BIN="$b"
        echo "🔹 Running special test: testendless (endless loop detection) [$b]"
        output=$($b test/testendless.lua --lualib-cpath="./$cpath/?.so;./$cpath/?.dll" 2>&1)
        if echo "$output" | grep -q "endless loop"; then
            echo "✅ Passed: testendless (endless loop warning detected) [$b]"
        else
            echo "❌ Failed: testendless (endless loop warning NOT detected) [$b]"
            echo "Output was:"
            echo "$output"
            return 1
        fi
    done
    return 0
}
# ---- Detect parallelism ----
JOBS=1
if [ "$PARALLEL_MODE" -eq 1 ] && [ "$PLATFORM" = "linux" ]; then
    JOBS=$(nproc 2>/dev/null || echo 1)
fi

echo "🧪 Platform: $PLATFORM"
echo "🧬 Binaries: $BINARIES"
echo "🧰 Test arguments: $ARGS"
if [ $JOBS -gt 1 ]; then
    echo "⚙️  Parallel jobs: $JOBS"
fi
echo "📂 Scanning test directory: $TEST_DIR"

# POSIX-compatible sorting (works on macOS / Linux)
# Search in test/ and test/adt/ directories for files starting with "test"
# Exclude test.lua, testprometheus.lua (requires prometheus), testendless.lua (special handling)
if [ -n "$OVERRIDE_SET" ]; then
    TEST_FILES="$TEST_DIR/$OVERRIDE_SET.lua"
    if [ ! -f "$TEST_FILES" ]; then
        echo "❌ Error: test case not found: $TEST_FILES"
        exit 1
    fi
else
    TEST_FILES=$(find "$TEST_DIR" "$TEST_DIR/adt" -maxdepth 1 -type f -name 'test*.lua' ! -name 'test.lua' ! -name 'testprometheus.lua' ! -name 'testendless.lua' 2>/dev/null | sort)
fi
if [ -z "$TEST_FILES" ]; then
    echo "⚠️  No test files (*.lua) found"
    exit 1
fi

# ---- Filter tests based on platform ----
FILTERED_TESTS=""
SERIAL_TESTS=""  # Tests that must run serially
SKIPPED=0
for file in $TEST_FILES; do
    # Remove 'test/' prefix and '.lua' suffix to get the case name
    # e.g., test/adt/testqueue.lua -> adt/testqueue
    base=$(echo "$file" | sed 's|^test/||' | sed 's|\.lua$||')
    filename=$(basename "$file" .lua)

    # Skip certain tests on non-Linux platforms
    if [ "$PLATFORM" != "linux" ] && { [ "$filename" = "testmysql" ] || [ "$filename" = "testredis" ]; }; then
        echo "⏭️  Skipping test: $base (only runs on Linux)"
        SKIPPED=$((SKIPPED + 1))
    else
        # Mark tests that need serial execution (database tests, resource-sensitive tests)
        case "$filename" in
            testmysql|testredis)
                SERIAL_TESTS="$SERIAL_TESTS $base"
                ;;
            *)
                FILTERED_TESTS="$FILTERED_TESTS $base"
                ;;
        esac
    fi
done

# ---- Run tests ----
if [ $JOBS -eq 1 ]; then
    # Serial execution
    TOTAL=0
    PASSED=0
    FAILED=0
    LOGDIR=$(mktemp -d)
    trap 'rm -rf "$LOGDIR"' EXIT
    # Combine all tests (parallel-eligible and serial tests)
    all_tests="$FILTERED_TESTS $SERIAL_TESTS"

    # Create subdirectories for test cases with paths (e.g., adt/testqueue)
    for t in $all_tests; do
        test_dir=$(dirname "$t")
        if [ "$test_dir" != "." ]; then
            mkdir -p "$LOGDIR/$test_dir"
        fi
    done

    for base in $all_tests; do
        rc=0
        for b in $BINARIES; do
            cpath="luaclib"
            if [ "$b" = "./silly.asan" ]; then
                cpath="luaclib.asan"
            elif [ "$b" = "./silly.tsan" ]; then
                cpath="luaclib.tsan"
            fi
            export SILLY_LUACLIB_PATH="$cpath"
            export SILLY_BIN="$b"
            echo "🔹 Running test: $base [$b]"
            logfile="$LOGDIR/$base.$(basename "$b").log"
            if [ -n "$SET_ARG" ]; then
                setarg="$SET_ARG"
            else
                setarg="--set=$base"
            fi
            set +e
            # Run test with output to both terminal and log file.
            # Use a status file to capture the real exit code through tee pipe.
            rcfile="$LOGDIR/$base.$(basename "$b").rc"
            ( $b "$TEST_SCRIPT" $setarg --lualib-cpath="./$cpath/?.so;./$cpath/?.dll" $ARGS 2>&1; echo $? > "$rcfile" ) | tee "$logfile"
            rc=$(cat "$rcfile" 2>/dev/null || echo 1)
            set -e
            if [ $rc -eq 0 ] && grep -Eq "(^|[^A-Za-z0-9_])FAIL([^A-Za-z0-9_]|$)" "$logfile"; then
                rc=1
            fi
            if [ $rc -ne 0 ]; then
                break
            fi

            # On mingw, add delay between tests to let Windows clean up resources
            if [ "$PLATFORM" = "mingw" ]; then
                sleep 0.5
            fi
        done

        TOTAL=$((TOTAL + 1))
        if [ $rc -eq 0 ]; then
            echo "✅ Passed: $base (all binaries)"
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
else
    # Parallel execution in batches
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    # Create subdirectories for test cases with paths (e.g., adt/testqueue)
    for t in $FILTERED_TESTS $SERIAL_TESTS; do
        test_dir=$(dirname "$t")
        if [ "$test_dir" != "." ]; then
            mkdir -p "$TMPDIR/$test_dir"
        fi
    done

    # Color codes
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m' # No Color

    # Count total tests (parallel + serial)
    PARALLEL_COUNT=$(echo "$FILTERED_TESTS" | wc -w)
    SERIAL_COUNT=$(echo "$SERIAL_TESTS" | wc -w)
    TOTAL_TESTS=$((PARALLEL_COUNT + SERIAL_COUNT))

    echo ""
    if [ $SERIAL_COUNT -gt 0 ]; then
        echo "🏃 Running $TOTAL_TESTS tests ($PARALLEL_COUNT parallel in batches of $JOBS, $SERIAL_COUNT serial)..."
    else
        echo "🏃 Running $TOTAL_TESTS tests in batches of $JOBS..."
    fi
    echo ""

    # Convert to array for batching
    test_array=""
    for t in $FILTERED_TESTS; do
        test_array="$test_array$t "
    done

    batch_num=0
    completed=0

    while [ $completed -lt $TOTAL_TESTS ]; do
        batch_num=$((batch_num + 1))
        batch_tests=""
        batch_count=0

        # Collect tests for this batch
        for t in $test_array; do
            [ -f "$TMPDIR/$t.status" ] && continue
            [ -f "$TMPDIR/$t.processing" ] && continue

            batch_tests="$batch_tests$t "
            batch_count=$((batch_count + 1))
            touch "$TMPDIR/$t.processing"

            [ $batch_count -ge $JOBS ] && break
        done

        [ -z "$batch_tests" ] && break

        # Show testing status - each test on its own line
        # Record line number for each test
        test_num=$completed
        line_num=0
        for t in $batch_tests; do
            test_num=$((test_num + 1))
            echo "$line_num" > "$TMPDIR/$t.line"
            printf "${YELLOW}Testing:${NC}    %-18s (%d/%d)\n" "$t" "$test_num" "$TOTAL_TESTS"
            line_num=$((line_num + 1))
        done

        # Start monitoring in background
        (
            while true; do
                all_done=1
                for t in $batch_tests; do
                    [ -f "$TMPDIR/$t.updated" ] && continue
                    [ ! -f "$TMPDIR/$t.status" ] && all_done=0 && continue

                    # Mark as updated
                    touch "$TMPDIR/$t.updated"

                    # Get line number
                    line=$(cat "$TMPDIR/$t.line")
                    status=$(cat "$TMPDIR/$t.status")
                    rc=${status%%:*}
                    bin=${status#*:}
                    [ "$bin" = "$status" ] && bin=""

                    # Calculate test number
                    test_idx=$((completed + line + 1))

                    # Move to the specific line and update
                    move_up=$((batch_count - line))
                    printf "\033[%dA" "$move_up"

                    if [ "$rc" -eq 0 ]; then
                        printf "\r${GREEN}✓ SUCCESS${NC}: %-18s (%d/%d) [all]\033[K\n" "$t" "$test_idx" "$TOTAL_TESTS"
                    else
                        if [ -n "$bin" ]; then
                            printf "\r${RED}✗ FAIL${NC}:    %-18s (%d/%d) [%s exit: %d]\033[K\n" "$t" "$test_idx" "$TOTAL_TESTS" "$bin" "$rc"
                        else
                            printf "\r${RED}✗ FAIL${NC}:    %-18s (%d/%d) [exit code: %d]\033[K\n" "$t" "$test_idx" "$TOTAL_TESTS" "$rc"
                        fi
                    fi

                    # Move back to bottom
                    move_down=$((batch_count - line - 1))
                    [ $move_down -gt 0 ] && printf "\033[%dB" "$move_down"
                done

                [ $all_done -eq 1 ] && break
                sleep 0.1
            done
            touch "$TMPDIR/.batch$batch_num.done"
        ) &
        MONITOR_PID=$!

        # Run batch in parallel (pass variables via environment to avoid quoting issues with dash)
        export _TS_TMPDIR="$TMPDIR"
        export _TS_TEST_SCRIPT="$TEST_SCRIPT"
        export _TS_ARGS="$ARGS"
        export _TS_BINARIES="$BINARIES"
        export _TS_OVERRIDE_SET="$OVERRIDE_SET"
        echo "$batch_tests" | tr ' ' '\n' | grep -v '^$' | xargs -P "$JOBS" -I {} sh -c '
            base={}
            logfile="$_TS_TMPDIR/$base.log"
            echo "🔹 Running test: $base" > "$logfile"

            rc=0
            failed_bin=""
            for b in $_TS_BINARIES; do
                cpath="luaclib"
                if [ "$b" = "./silly.asan" ]; then
                    cpath="luaclib.asan"
                elif [ "$b" = "./silly.tsan" ]; then
                    cpath="luaclib.tsan"
                fi
                export SILLY_LUACLIB_PATH="$cpath"
                export SILLY_BIN="$b"
                echo "-> $b" >> "$logfile"
                if [ -n "$_TS_OVERRIDE_SET" ]; then
                    setarg="--set=$_TS_OVERRIDE_SET"
                else
                    setarg="--set=$base"
                fi
                set +e
                $b "$_TS_TEST_SCRIPT" $setarg --lualib-cpath="./$cpath/?.so;./$cpath/?.dll" $_TS_ARGS >> "$logfile" 2>&1
                rc=$?
                set -e
                if [ $rc -ne 0 ]; then
                    failed_bin=$b
                    break
                fi
            done
            if [ $rc -eq 0 ] && grep -Eq "(^|[^A-Za-z0-9_])FAIL([^A-Za-z0-9_]|$)" "$logfile"; then
                rc=1
            fi
            echo "$rc:$failed_bin" > "$_TS_TMPDIR/$base.status"
        '

        # Wait for monitor to finish
        wait $MONITOR_PID 2>/dev/null

        # Update completed count
        completed=$((completed + batch_count))
    done

    # Run serial tests one by one
    if [ -n "$SERIAL_TESTS" ]; then
        echo "${YELLOW}━━━ Running Serial Tests ━━━${NC}"
        echo ""
        for t in $SERIAL_TESTS; do
            completed=$((completed + 1))
            printf "${YELLOW}Testing:${NC}    %-18s (%d/%d)\n" "$t" "$completed" "$TOTAL_TESTS"

            logfile="$TMPDIR/$t.log"
            echo "🔹 Running test: $t" > "$logfile"

            rc=0
            failed_bin=""
            for b in $BINARIES; do
                cpath="luaclib"
                if [ "$b" = "./silly.asan" ]; then
                    cpath="luaclib.asan"
                elif [ "$b" = "./silly.tsan" ]; then
                    cpath="luaclib.tsan"
                fi
                export SILLY_LUACLIB_PATH="$cpath"
                export SILLY_BIN="$b"
                echo "-> $b" >> "$logfile"
                if [ -n "$SET_ARG" ]; then
                    setarg="$SET_ARG"
                else
                    setarg="--set=$t"
                fi
                set +e
                $b "$TEST_SCRIPT" $setarg --lualib-cpath="./$cpath/?.so;./$cpath/?.dll" $ARGS >> "$logfile" 2>&1
                rc=$?
                set -e
                if [ $rc -ne 0 ]; then
                    failed_bin=$b
                    break
                fi
            done
            if [ $rc -eq 0 ] && grep -Eq "(^|[^A-Za-z0-9_])FAIL([^A-Za-z0-9_]|$)" "$logfile"; then
                rc=1
            fi
            echo "$rc:$failed_bin" > "$TMPDIR/$t.status"
            if [ "$rc" -eq 0 ]; then
                # Move up one line, clear, and print success
                printf "\033[1A\r${GREEN}✓ SUCCESS${NC}: %-18s (%d/%d) [all]\033[K\n" "$t" "$completed" "$TOTAL_TESTS"
            else
                # Move up one line, clear, and print failure
                if [ -n "$failed_bin" ]; then
                    printf "\033[1A\r${RED}✗ FAIL${NC}:    %-18s (%d/%d) [%s exit: %d]\033[K\n" "$t" "$completed" "$TOTAL_TESTS" "$failed_bin" "$rc"
                else
                    printf "\033[1A\r${RED}✗ FAIL${NC}:    %-18s (%d/%d) [exit code: %d]\033[K\n" "$t" "$completed" "$TOTAL_TESTS" "$rc"
                fi
            fi
        done
        echo ""
    fi

    # Collect results
    TOTAL=0
    PASSED=0
    FAILED=0
    FAILED_TESTS=""

    echo ""
    echo "📋 Test Results Summary:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Collect results from both parallel and serial tests
    all_tests="$FILTERED_TESTS $SERIAL_TESTS"
    for base in $all_tests; do
        TOTAL=$((TOTAL + 1))
        status=$(cat "$TMPDIR/$base.status" 2>/dev/null || echo 1)
        rc=${status%%:*}

        if [ "$rc" -eq 0 ]; then
            PASSED=$((PASSED + 1))
        else
            FAILED=$((FAILED + 1))
            FAILED_TESTS="$FAILED_TESTS $base"
            # Show failed test log
            printf "\n${RED}━━━ Failed Test: %s ━━━${NC}\n" "$base"
            tail -20 "$TMPDIR/$base.log" 2>/dev/null || echo "Log not available"
            printf "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        fi
    done

    echo ""
    if [ $FAILED -gt 0 ]; then
        printf "${RED}🛑 Failed tests (%d/%d):${NC}%s\n" "$FAILED" "$TOTAL" "$FAILED_TESTS"
        exit 1
    else
        printf "${GREEN}🎉 All tests passed: %d/%d${NC} (skipped: %d)\n" "$PASSED" "$TOTAL" "$SKIPPED"
        exit 0
    fi
fi
