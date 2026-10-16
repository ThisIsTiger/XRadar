# Contributing to XRadar

Thanks for taking the time to contribute. This document covers the local setup,
the checks your change must pass, and the conventions used in this repository.

## Requirements

- macOS 13 or later
- A Swift 6.3 toolchain:
  - **Xcode 15+** (recommended — also runs the `XCTest` suite), or
  - the **Swift.org Swift 6.3 toolchain** (enough for `swift build` / `swift test`
    in a headless environment)

## Getting started

```bash
git clone https://github.com/ThisIsTiger/XRadar.git
cd XRadar
./scripts/bootstrap.sh          # toolchain sanity check
swift build                     # debug build
./scripts/test.sh               # test suite (auto-selects XCTest or XRadarVerifier)
./scripts/verify.sh             # full verification (debug + release + tests + static checks)
./scripts/package.sh            # bundle dist/XRadar.app
```

Optionally enable the pre-commit hook (build + test before each commit):

```bash
git config core.hooksPath .githooks
```

## Before opening a pull request

Run the full verification and make sure it is green:

```bash
./scripts/verify.sh
```

`verify.sh` performs a Debug build, a Release build, the test suite, a static
hygiene pass (no `TODO`/`FIXME` markers, no secrets, no `print()` in production
code, no `/tmp` writes, no direct `$appModel.configuration.` bindings), and a
required-files check. A red `verify.sh` will not be merged.

`scripts/test.sh` auto-detects the environment: with Xcode it runs the `XCTest`
suite via `swift test`; with Command-Line-Tools only it builds and runs
`XRadarVerifier`, an XCTest-free runner over the same production logic.

## Architecture rules

- **Keep `XRadarCore` SwiftUI-free.** All logic lives in `Sources/XRadarCore`
  (models, rules, timeline, persistence, notifications, scheduling, pipeline,
  session, utilities). Do not import `SwiftUI` / `SwiftUICore` there — the app
  target `XRadar/` owns the views.
- **Respect actor isolation.** `AppModel` is `@MainActor`; `PollScheduler` and
  `MonitoringPipeline` are actors; repositories are `@MainActor`.
- **Protocol-oriented seams.** Extend `TimelineProvider`, `NotificationChannel`,
  or `RuleEvaluating` rather than branching on concrete types.
- **No new abstractions without a need.** Prefer the simplest change that fully
  solves the current problem, and lean on the dependencies already in the project.

## Code style

- Swift 6 with strict concurrency; explicit `self.`; no force unwraps.
- Propagate errors with `throws` / typed errors instead of swallowing them.
- No comments unless asked. No `print()` in production code — use `os.log`
  `Logger`.
- Never log secrets. Telegram credentials stay in the Keychain; no cookie values
  ever reach business logic; do not log full page content.

## Tests

- Add focused unit coverage for logic (`XRadarTests`, XCTest).
- Mirror anything reachable headlessly in `XRadarVerifier/main.swift` (register
  the check in the runner's list) so Command-Line-Tools-only environments cover
  it too.
- When you change RSS/Atom parsing or the pipeline, update both the XCTest
  mirror and the verifier checks.

## Reporting bugs

Open an issue with: what you expected, what happened, macOS + Swift version, the
affected source (X account rule vs custom RSS vs RSSHub), and — if relevant —
the diagnostics export from Settings → 通用 → 导出诊断日志 (OSS redacts secrets).
