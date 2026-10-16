#!/bin/bash
#
# Unified verification for XRadar.
#
# Runs, in order:
#   1. Debug build
#   2. Release build
#   3. All automated tests (headless XRadarVerifier; see note below)
#   4. Sensitive-info + static checks (no TODO/FIXME/unimplemented markers or
#      hardcoded secrets in production code)
#   5. Required documentation files present
#
# NOTE on testing: the XCTest suite (XRadarTests) requires Xcode.app /
# XCTest.framework and is run via `swift test` in a full Xcode environment.
# This headless CLI-tools environment has no XCTest.framework, so step 3 runs
# XRadarVerifier instead -- an XCTest-free runner that exercises the exact same
# production logic and the full acceptance checklist (account URL parsing,
# keyword matching, first baseline, dedup across restart, scheduler
# re-entrancy, state persistence, Telegram error handling, login state machine,
# and the mock full chain).
#
# Exits non-zero on the first category that fails. Swift is invoked with
# --disable-sandbox (the command sandbox blocks SwiftPM's nested sandbox-exec),
# and output is redirected to a log (piping swift output can raise SIGPIPE).
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SWIFT="$(command -v swift || echo /usr/bin/swift)"
FAIL=0

section() { echo ""; echo "=== $1 ==="; }

# ---------------------------------------------------------------------------
# 1. Debug build
# ---------------------------------------------------------------------------
section "1. Debug build"
if $SWIFT build --disable-sandbox -j 4 > /tmp/xradar_verify_build.log 2>&1; then
    echo "OK Debug build succeeded"
else
    echo "FAIL Debug build failed"; tail -n 30 /tmp/xradar_verify_build.log; FAIL=1
fi

# ---------------------------------------------------------------------------
# 2. Release build
# ---------------------------------------------------------------------------
section "2. Release build"
if $SWIFT build -c release --disable-sandbox -j 4 > /tmp/xradar_verify_release.log 2>&1; then
    echo "OK Release build succeeded"
else
    echo "FAIL Release build failed"; tail -n 30 /tmp/xradar_verify_release.log; FAIL=1
fi

# ---------------------------------------------------------------------------
# 3. Tests (headless verifier)
# ---------------------------------------------------------------------------
section "3. Tests (XRadarVerifier)"
if $SWIFT build --disable-sandbox -j 4 --product XRadarVerifier > /tmp/xradar_verify_verifier_build.log 2>&1 \
   && ./.build/debug/XRadarVerifier > /tmp/xradar_verify_verifier.log 2>&1; then
    echo "OK All XRadarVerifier checks passed"
else
    echo "FAIL XRadarVerifier failed"; tail -n 50 /tmp/xradar_verify_verifier.log; FAIL=1
fi

# ---------------------------------------------------------------------------
# 4. Sensitive-info + static checks
# ---------------------------------------------------------------------------
section "4. Sensitive-info & static checks"
SENSITIVE=0

# Scan production sources only (tests/verifier may intentionally use mocks or
# placeholder data). Production code now lives in `XRadar` (UI) and
# `Sources/XRadarCore` (core logic).
while IFS= read -r -d '' f; do
    if grep -nE '\b(TODO|FIXME|XXX)\b' "$f" > /dev/null; then
        echo "FAIL Found TODO/FIXME/XXX in $f:"; grep -nE '\b(TODO|FIXME|XXX)\b' "$f"; SENSITIVE=1
    fi
    if grep -nE 'fatalError\(|preconditionFailure\(|not implemented|unimplemented' "$f" > /tmp/_xradar_markers.txt 2>/dev/null; then
        # Allow the idiomatic AppKit/UIKit required-init boilerplate:
        #   fatalError("init(coder:) has not been implemented")
        # which is a required initializer that is never called for
        # programmatically-created view controllers (not a fake stub).
        if grep -qv 'init(coder:) has not been implemented' /tmp/_xradar_markers.txt; then
            echo "FAIL Found unimplemented marker in $f:"
            grep -v 'init(coder:) has not been implemented' /tmp/_xradar_markers.txt
            SENSITIVE=1
        fi
    fi
done < <(find XRadar Sources/XRadarCore -name '*.swift' -print0)

# No hardcoded Telegram tokens in production code (tokens live only in Keychain).
if grep -rnE 'bot[0-9]{6,}:[A-Za-z0-9_-]{20,}' XRadar Sources/XRadarCore --include='*.swift' > /dev/null; then
    echo "FAIL Possible hardcoded Telegram token found in production code"; SENSITIVE=1
fi

# UI binding hygiene: settings views must not two-way bind into AppModel.configuration
# directly (such writes skip the persistence path and are lost on restart). All
# mutations must go through AppModel setter methods.
BINDING_HITS=$(grep -rn '\$appModel\.configuration\.' XRadar/UI --include='*.swift' | grep -v 'get:' || true)
if [[ -n "$BINDING_HITS" ]]; then
    echo "FAIL Direct \$appModel.configuration bindings found (bypass persistence):"
    echo "$BINDING_HITS"
    SENSITIVE=1
fi

# Privacy hygiene: production code must never dump page content to /tmp
# (world-readable; may contain private tweets/identity) and must use Logger,
# not print().
if grep -rn '"/tmp/' Sources/XRadarCore XRadar --include='*.swift' > /dev/null; then
    echo "FAIL Writing to /tmp in production code:"
    grep -rn '"/tmp/' Sources/XRadarCore XRadar --include='*.swift'
    SENSITIVE=1
fi
if grep -rn 'print(' Sources/XRadarCore XRadar --include='*.swift' > /dev/null; then
    echo "FAIL print() used in production code (use os.log Logger):"
    grep -rn 'print(' Sources/XRadarCore XRadar --include='*.swift'
    SENSITIVE=1
fi

if [[ $SENSITIVE -eq 0 ]]; then
    echo "OK Static hygiene: no markers/secrets/bindings/tmp-writes/print()"
else
    FAIL=1
fi

# ---------------------------------------------------------------------------
# 5. Required files
# ---------------------------------------------------------------------------
section "5. Required files"
for f in README.md AGENTS.md CHANGELOG.md LICENSE CONTRIBUTING.md SECURITY.md; do
    if [[ -e "$f" ]]; then
        echo "OK $f"
    else
        echo "FAIL missing $f"; FAIL=1
    fi
done

# ---------------------------------------------------------------------------
if [[ $FAIL -eq 0 ]]; then
    echo ""; echo "SUCCESS verify.sh: ALL CHECKS PASSED"
    exit 0
else
    echo ""; echo "FAILURE verify.sh: CHECKS FAILED"
    exit 1
fi
