#!/bin/bash
# Generate HTML coverage report from luacov.report.out (lcov format)

set -e

REPORT_FILE="${1:-coverage/luacov.report.out}"

if [ ! -f "$REPORT_FILE" ]; then
    echo "⚠️  $REPORT_FILE not found. Run tests first."
    exit 1
fi

echo "📊 Generating Lua coverage HTML report from $REPORT_FILE..."
mkdir -p coverage/luacov-html

genhtml "$REPORT_FILE" \
    --output-directory coverage/luacov-html \
    --title "Silly Lua Coverage" \
    --legend --show-details

echo ""
echo "✅ HTML report: coverage/luacov-html/index.html"
