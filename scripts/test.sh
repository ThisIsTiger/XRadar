#!/bin/bash
#
# Run XRadar's automated checks.
#
# Detection: if a full Xcode.app is selected (which provides XCTest.framework
# and the test host), run the XCTest suite via `swift test`. Otherwise (a
# Command-Line-Tools-only install, where `swift test` cannot link XCTest),
# build and run XRadarVerifier -- an XCTest-free runner that exercises the
# same production logic and the full acceptance checklist.
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "Testing XRadar..."

if xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
    echo "Xcode detected -- running the XCTest suite."
    swift test --disable-sandbox -j 4
else
    echo "Xcode not selected (Command-Line-Tools only) -- running the headless XRadarVerifier."
    swift build --disable-sandbox -j 4 --product XRadarVerifier
    ./.build/debug/XRadarVerifier
fi
