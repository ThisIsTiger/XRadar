#!/bin/bash
#
# XRadar development bootstrap — macOS + Swift toolchain check.
#
set -e

echo "Bootstrapping XRadar development environment..."

if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "Error: XRadar requires macOS"
    exit 1
fi

if ! command -v swift &> /dev/null; then
    echo "Error: Swift not found. Install Xcode (or the Swift.org toolchain) first."
    exit 1
fi

echo "Swift version:"
swift --version

echo ""
echo "Optionally enable the pre-commit hook (build + test before each commit):"
echo "    git config core.hooksPath .githooks"
echo ""
echo "Bootstrap complete!"
echo ""
echo "Next steps:"
echo "1. swift build            # debug build"
echo "2. ./scripts/test.sh      # run the test suite"
echo "3. ./scripts/verify.sh    # full verification (debug + release + tests + static checks)"
echo "4. ./scripts/package.sh   # bundle dist/XRadar.app"
