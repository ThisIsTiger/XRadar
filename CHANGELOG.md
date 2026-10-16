# Changelog

All notable changes to XRadar will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-23

First public release. XRadar is a native macOS menu bar app that watches X
accounts and arbitrary RSS/Atom feeds for keywords and notifies you via macOS
notifications and/or Telegram.

### Added

- **Menu bar app** with status display, recent events, a "check now" action, and
  a tabbed settings window (信源 / 监控规则 / 抓取配置 / 通知 / 通用).
- **Monitoring rules** with configurable X account handles, keyword matching
  (any/all), exclusion keywords, case sensitivity, and include/exclude of replies
  and reposts; multiple notification channels per rule.
- **Custom RSS source rules** (`MonitorRule.feedURL`): any HTTP(S) RSS/Atom feed
  can be monitored without an RSSHub instance or X login. Entries are matched by
  title/summary; link and author come straight from the feed. A first fetch only
  establishes a baseline; items published in the last three days participate in
  rule evaluation.
- **RSSHub source**: pluggable `TimelineProvider` implementations (RSSHub + X
  WebView) behind `XTimelineRouter`, with an `XSourcePolicy` (RSSHub only / X
  WebView only / RSSHub with X fallback). Instances are user-supplied — no
  instances are bundled. Adding, removing, reordering, and a side-effect-free
  "test source" button live in the 信源 settings tab.
- **Source-aware fetch semantics**: a tweet participates in rule evaluation when
  its ID is unseen and it falls inside the three-day window; no
  `publishedAt > lastFetch` gate. Empty feeds do not initialize a cursor.
- **Conditional requests**: ETag/304 support, a 5 MiB response cap, same-host
  redirect allowlisting, and untrusted 2xx-empty-feed detection.
- **Fetch diagnostics**: `FetchRecord` records the provider, instance host, fall
  back source, tweet time, fetch time, and failure reason; the fetch-history
  window surfaces them.
- **In-app X login** using WKWebView with a persistent, isolated session
  (challenges and rate limits are surfaced with automatic backoff).
- **Keyword normalization**: Unicode canonical normalization, case folding,
  fullwidth/halfwidth conversion, and diacritic-insensitive matching, plus
  left-word-boundary semantics for pure ASCII keywords.
- **Local JSON persistence**: atomic writes, backup and recovery, schema
  versioning, and per-account cursors for cross-restart deduplication.
- **Notifications**: macOS `UNUserNotificationCenter` (category with actions,
  sound) and a Telegram bot (HTML formatting, inline keyboard, 429 retry,
  Keychain-only credentials).
- **Poll scheduler**: configurable intervals (1/5/10/30/60 min), launch and wake
  detection, manual trigger, jitter for scheduled runs, and rate-limit backoff.
- **Security**: isolated website data store, Keychain for secrets, no credential
  logging, no browser-cookie access, and `SourceError`-typed RSS failures.

### Changed

- **Module split**: SwiftUI-free logic lives in a separate `XRadarCore` SPM
  module (`Sources/XRadarCore`); the `XRadar` app depends on it. This keeps
  `SwiftUICore` out of the core/CLI targets and enables headless testing.
- **Headless verification**: `XRadarVerifier`, an XCTest-free runner that checks
  the full acceptance checklist via `@testable import XRadarCore`.
  `scripts/test.sh` / `scripts/verify.sh` fall back to it when
  `XCTest.framework` is unavailable.
- **Visual refresh (Liquid Glass)**: a shared `GlassStyle` material set — system
  `glassEffect` on macOS 26+, `ultraThinMaterial` fallback on older systems —
  used for the status badge, menu bar cards, settings forms, and history lists.
- **Menu bar status**: the status line links straight to the relevant settings
  tab and shows the next scheduled check (`下次检查 ≈HH:mm`), including the real
  backoff deadline.
- **Scheduler**: ±20% jitter is applied only to scheduled runs; RSSHub 429
  backoff honors `Retry-After` (default 15 min) with a 2 min transient default;
  no checks (including the manual one) run while the source is unconfigured.
- **Error semantics**: RSS failures use concrete `SourceError` cases and are
  never reported as "X page structure changed"; a rejected redirect is reported
  as `.redirectRejected`; all instances cooling down raises
  `.instancesCoolingDown` (WebView fallback eligible).
- **Diagnostics de-noised**: a source that keeps failing with the same root cause
  writes a single failure entry until the cause changes.
- **Notification gateway**: delivery policy is applied at launch and whenever
  settings change, so channel/sound toggles take effect immediately.
- **Settings persistence**: polling, general, and notification toggles/selectors
  persist through `AppModel` setters; the history retention and event-cap knobs
  drive `EventRepository`.
- 编辑规则切换选中项时强制重建编辑器（`.id(rule.id)`）。
- 版本号读取 Bundle 信息，不再写死；重置应用补全（持久化默认配置、清空抓取
  历史、刷新界面）。

### Fixed

- **Fat-feed history replay**: `finalize` used to exclude seen items and then cap,
  which made feeds with far more than ten items replay older pages as new each
  round. Order is now window → deterministic sort (with a string-ID tiebreak) →
  newest-page cap → exclude seen last.
- **WebView empty-page HTML leak**: a failed fetch wrote the entire page (private
  tweets and identity included) to a world-readable `/tmp` file and never cleaned
  it up. Removed; static guards now forbid `/tmp` writes and `print()` in
  production code.
- **Notification toggles had no effect**: `NotificationGateway.configure()` was
  never called, so delivery stayed on for every channel regardless of settings.
- **Paused-state bypass**: `PollScheduler.triggerNow` let manual and wake checks
  through while paused.
- **Compile breakage**: `RSSHubTimelineProvider` now resolves validators via
  `request.httpValidators[sourceKey]`, and `.httpStatus` /
  `.instancesCoolingDown` are handled exhaustively.
- **ETag/304 wiring**: cursors' validators are sent with each request (keyed by
  instance host for RSSHub, by feed URL for custom RSS) and response ETags are
  stored back; `TimelineFetchResult.httpValidator` is no longer dropped.
- **Feed-rule visibility**: menu bar and fetch history attribute feed records by
  source URL (previously matched by display name and always showed "no records").
- **Rule editor gating**: saving is blocked for an invalid feed URL or a
  keyword-mode rule with no keywords.
- **RequestBuilder regression**: removed the over-strict handle character check
  (e.g. `a_b-c` is a valid path segment).
- **RFC 822 named time zones**: date parsing now handles `GMT`-style zones.
- **Notification robustness**: permission requests guard on
  `Bundle.main.bundleIdentifier`; the WKWebView navigation policy delegate
  signature matches the protocol so HTTPS-only enforcement actually fires.
- **Status classification**: transient-vs-permanent is decided solely by the
  structured `isTransientError` flag (no error-text substring matching).
- Public RSSHub Twitter routes are largely defunct (302/503/403); all bundled
  instance presets were removed and instance URLs are user-supplied and verified.

### Security

- RSSHub instances may not embed credentials, query strings, or fragments; HTTPS
  only (localhost `http` allowlisted). Requests use an ephemeral session with no
  cookies, and redirects to `x.com` / `twitter.com` are disabled.
- Custom RSS sources reject `x.com` / `twitter.com` hosts (use an X account rule).

### Technical

- `XRadarVerifier` covers 39 checks (parsing, RSS/Atom mapping + safety, Router
  policy/fallback, cursor semantics, scheduling jitter and gates, keyword
  boundary, notification policy, pause gates, status classification, failure
  provider hints, cooldown de-noising, persistence, login state machine, full
  mock chain).
- Config schema is at v2 (source settings) with lossless v1→v2 migration;
  `fetch-history.json` wrapper is at v4 with backward-decodable records.

### Documentation

- `README.md` user guide, `DESIGN.md` architecture, `DESIGN-RSSHUB.md` RSSHub /
  custom-RSS specification, `AGENTS.md` contributor/agent guide, `CONTRIBUTING.md`,
  and `SECURITY.md`.

## Version Format

- `MAJOR.MINOR.PATCH` ([Semantic Versioning](https://semver.org/spec/v2.0.0.html))
- MAJOR: incompatible changes
- MINOR: backward-compatible features
- PATCH: backward-compatible bug fixes

## Categories

- `Added`: new features
- `Changed`: changes to existing functionality
- `Deprecated`: soon-to-be removed features
- `Removed`: removed features
- `Fixed`: bug fixes
- `Security`: security improvements
- `Technical`: internal/development changes
- `Documentation`: documentation updates
