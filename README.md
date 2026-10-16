# XRadar

XRadar is a lightweight, native macOS menu bar application that monitors X (Twitter) accounts for keywords and sends notifications when matching tweets are detected.

## Features

- **Menu Bar Application**: Runs unobtrusively in your macOS menu bar
- **In-App X Login**: Securely login to X using the built-in WebView
- **Keyword Monitoring**: Configure rules to watch for specific keywords or phrases
- **Multiple Match Modes**: Match any or all keywords, with exclusion support
- **Dual Notifications**: Receive alerts via macOS native notifications and/or Telegram Bot
- **Smart Deduplication**: Avoid duplicate notifications with intelligent tweet tracking
- **Configurable Polling**: Choose from 1, 5, 10, 30, or 60 minute check intervals
- **Privacy First**: All data stored locally, no external servers

## Requirements

- macOS 13.0 or later
- Apple Silicon (arm64) or Intel (x86_64) Mac
- A Swift 6.3 toolchain. Either:
  - **Xcode 15+** (also runs the `XCTest` suite via `swift test`), or
  - The **Swift.org Swift 6.3 toolchain** (sufficient for `swift build` / `swift test` in a headless / CI environment where Xcode is not installed)

> The Liquid Glass visuals (`glassEffect`) require the **macOS 26 SDK**
> (Xcode 26+). On older toolchains/systems the UI automatically falls back to
> `ultraThinMaterial`; nothing else changes.

## Installation

### Option 1: Build from Source (recommended)

XRadar is built with the Swift Package Manager. This produces a native
executable that runs as a macOS menu-bar app.

```bash
# Clone the repository
git clone https://github.com/ThisIsTiger/XRadar.git
cd XRadar

# Build the project
swift build
# (or a Release build)
swift build -c release

# Run the automated tests (auto-selects XCTest when available, else XRadarVerifier)
./scripts/test.sh

# Run the unified verification (debug build + release build + tests + static checks)
./scripts/verify.sh
```

> XRadar is distributed as source. `swift build` / `swift test` work with either
> Xcode or the Swift.org toolchain; producing a notarized, redistributable `.app`
> is out of scope for this repository.

### Option 2: Package a local `.app`

If you want a double-clickable app bundle, run the packaging script — it builds
a release binary and assembles `dist/XRadar.app` (ad-hoc signed for local use):

```bash
./scripts/package.sh
open dist/XRadar.app
```

> XRadar is distributed **as source only**. No pre-built or notarized binary is
> provided; the ad-hoc signature from `package.sh` is fine for your own machine
> but is not suitable for redistribution.

## Usage

### First Launch

1. **Grant Notification Permission**: XRadar will request permission to send notifications on first launch
2. **Configure a Source**: Open Settings → 信源 and add an RSSHub instance URL you own or have verified yourself. The app ships with no bundled instances. X login is only needed when you choose the X WebView policies
3. **Create Monitoring Rules**: Add rules for accounts you want to monitor with your keywords

### Configuring the RSSHub Source

XRadar can fetch timelines either from an RSSHub instance or through the built-in
X WebView, selectable via 抓取策略 in Settings → **信源**.

- **RSSHub（推荐）**: recommended default. Add one or more RSSHub instance
  URLs you own or have verified yourself (e.g. self-hosted
  `http://localhost:1200`). No instances are bundled with the app. Instances
  are tried in order; the first usable one is used for each account.
  Instance URLs must be `https://` (or a localhost/127.0.0.1 `http://`) with **no
  credentials, query strings, or fragments** embedded.
- **应用内 X 登录抓取**: falls back to the WebView authentication path; requires
  logging in to X.
- **RSSHub 失败后回退 X**: if every configured RSSHub instance fails, the app
  may open the built-in browser against X to fetch. **This carries a risk of
  your X account being flagged (风控).** You must explicitly acknowledge the risk
  before this policy can be saved or take effect.

The **"测试信源"** button performs a single side-effect-free fetch against the
first configured instance (no cursors, history, events, notifications, or WebView
fallback are touched) and reports the final host, HTTP status, raw/valid item
counts, latest publish time, duration, and any error.

### Creating Monitoring Rules

1. Open Settings from the menu bar
2. Go to the "监控规则" tab
3. Click the "+" button to add a rule
4. Configure:
   - **Rule Name**: A descriptive name for your reference
   - **Source Type**: "X 账号" or "自定义 RSS 源"
   - **X Account**: The handle to monitor (e.g., `elonmusk`)
   - **RSS Feed URL**: Any RSS/Atom subscription URL over HTTP(S), e.g.
     `https://example.com/feed.xml`（自定义 RSS 源规则）
   - **Trigger Mode**: "所有新推文" or "关键词触发"
   - **Keywords**: Add keywords to match (supports Chinese, English, phrases)
   - **Match Mode**: "任意关键词" (any) or "全部关键词" (all)
   - **Options**: Include replies, reposts, case sensitivity (X rules only)
   - **Notifications**: Enable macOS and/or Telegram notifications

> **自定义 RSS 源**：适用于监控任何站点的订阅更新，不依赖 RSSHub 实例、
> 不需要 X 登录。条目按标题/摘要匹配关键词，链接与作者直接来自订阅源；
> 首次抓取只建立基线，之后三天内出现的新条目参与规则判定。源地址必须为
> 绝对 http(s) URL，且不能是 x.com/twitter.com（请使用 X 账号规则）。
> 只要存在至少一个启用的自定义 RSS 源规则，自动抓取就会运行，无需配置
> RSSHub 实例。

### Telegram Bot Setup (Optional)

1. Create a Telegram bot via [@BotFather](https://t.me/botfather)
2. Get your Bot Token and Chat ID
3. In XRadar Settings → 通知:
   - Enable "启用 Telegram 通知"
   - Enter Bot Token and Chat ID
   - Click "发送测试消息" to verify

### Understanding Status Indicators

- **运行中**: Actively monitoring
- **暂停**: Monitoring paused
- **正在检查**: Currently fetching tweets
- **需要配置信源**: No usable RSSHub instance configured (or the fallback policy
  risk has not been acknowledged). Automatic and manual checks are disabled
  until the source is configured (unless at least one 自定义 RSS 源 rule is
  enabled — those rules run independently of RSSHub/X)
- **需要登录**: X login required
- **需要用户处理 X 验证**: X challenge/action required
- **已退避至 HH:mm**: Rate limited, retry scheduled
- **运行异常**: A non-transient error occurred (hover the history for details)

## Architecture

XRadar is built with:

- **Swift 6** with strict concurrency checking
- **SwiftUI** for modern, native UI
- **WKWebView** for X authentication and data fetching
- **Actor-based concurrency** for thread safety
- **Local JSON persistence** for configuration and state
- **Keychain** for secure credential storage

### Data Flow

```
Menu Bar UI ←→ AppModel ←→ Repositories ←→ JSONFileStore
                    ↓
              Scheduler ←→ Pipeline
                    ↓
      XTimelineRouter ──→ RSSHub 实例（无 Cookie，ETag/304）
              └────────→ X WebView（仅回退策略抓取）
              RSSDirectFeedProvider ──→ 自定义 RSS 源（无 Cookie，直连）
                    ↓
              RuleEngine ←→ NotificationGateway
                    ↓
              macOS / Telegram Notifications
```

## Privacy & Security

- **No Browser Cookies Accessed**: XRadar uses its own isolated `WKWebsiteDataStore`. It never reads your system browser's cookies, and X's session cookies are never exposed to business logic.
- **Login Session Persisted by WebKit**: The WebView login state is persisted in the app's isolated website data store, so you stay logged in across restarts. XRadar does **not** store your X password or any plaintext cookie.
- **Telegram Secrets**: The bot token and chat ID live **only** in the macOS Keychain (`KeychainStore`). They are never written to JSON config/state files, and a missing token degrades gracefully to local-only notifications.
- **Atomic, Recoverable Persistence**: Config and state are written atomically (temp file → `.bak` backup → swap). A corrupt main file is recovered from the `.bak`; if both are unusable the app falls back to safe defaults instead of crashing.
- **No Telemetry**: No analytics, tracking, or remote servers.
- **Third-Party RSSHub Instances**: The operators of a third-party RSSHub
  instance can see which accounts you query (the handle is part of the URL).
  Prefer self-hosted instances for private monitoring accounts.
- **Local Only**: All data stays on your Mac.
- **Respects X's Terms**: XRadar never bypasses CAPTCHAs, rate limits, or X's access controls. If X presents a challenge, you resolve it manually; the scheduler backs off and surfaces a clear status.

## Known Limitations

### MVP Scope

- **No CAPTCHA Bypass**: If X presents a challenge, you must resolve it manually
- **Web-Based Only**: Uses web interface; official X API not implemented (protocol supports future addition)
- **X Structure Dependency**: Tweet extraction depends on X's current DOM structure; may break if X changes their page layout
- **Single User**: Designed for personal monitoring use

### Technical Constraints

- **macOS Only**: Not available for iOS or other platforms
- **macOS 13+ Required**: Uses modern SwiftUI features
- **No Background Fetching**: macOS may suspend the app when not in use
- **Build Tooling**: Swift Package Manager. Use `swift build` for a debug/release
  binary, or `./scripts/package.sh` for a locally runnable `dist/XRadar.app`.
- **Test Execution**: The `XCTest` suite (`XRadarTests`) runs in Xcode, or in a
  headless environment that has the Swift.org Swift 6.3 toolchain (which bundles
  XCTest). A plain Command-Line-Tools install without Xcode cannot link
  `XCTest.framework`. For that environment, `XRadarVerifier` — an XCTest-free
  runner built from the same `XRadarCore` sources — covers the full acceptance
  checklist via `./scripts/test.sh` or `./scripts/verify.sh`.

## Troubleshooting

### "X 页面结构可能已变化" Error

If XRadar detects repeated page structure errors:

1. Wait for an app update that addresses the DOM change
2. Export diagnostics from Settings → 通用 → 导出诊断日志
3. Report the issue with the diagnostics attached

### Login Issues

- Ensure you can login to X normally in Safari/Chrome first
- XRadar uses its own cookie storage; it won't see your browser login
- If X presents a verification challenge, complete it in the login window

### No Notifications Received

1. Check macOS System Settings → Notifications → XRadar
2. Verify notification channels are enabled in XRadar Settings
3. Check that keywords actually match (case sensitivity matters if enabled)
4. First fetch establishes baseline and doesn't notify

### Telegram Not Working

- Verify Bot Token format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`
- Ensure Chat ID is correct (include `-` for groups)
- Test with the "发送测试消息" button
- Check that the bot has permission to send messages to the chat

## Development

### Project Structure

```
XRadar/
├── Sources/
│   └── XRadarCore/        # SwiftUI-free core logic (a separate SPM module so it
│       ├── Models/        #   can be unit-tested / run headless without pulling in
│       ├── Rules/         #   SwiftUICore, which the macOS 26 SDK forbids CLI tools
│       ├── Timeline/      #   from linking)
│       ├── Notifications/ # macOS + Telegram
│       ├── Persistence/   # JSON storage
│       ├── Security/      # Keychain
│       ├── Scheduling/    # Poll scheduler
│       ├── Pipeline/      # Processing pipeline
│       ├── Session/       # X login session (WebView)
│       └── Utilities/     # Handle parsing, etc.
├── XRadar/                # SwiftUI application (App + UI views), depends on XRadarCore
│   ├── App/               # App entry point, AppModel
│   └── UI/                # SwiftUI views (MenuBar, Settings, history, Style)
├── XRadarVerifier/        # XCTest-free headless verification runner
├── XRadarTests/           # XCTest suite (requires Xcode.app / XCTest.framework)
└── scripts/               # Build / test / verify scripts
```

### Git Hooks (Pre-commit Verification)

The repository ships a pre-commit hook in `.githooks/pre-commit` that runs the
core verification (debug build + tests) before each commit. Enable it with:

```bash
git config core.hooksPath .githooks
```

To skip the hook for a single commit:

```bash
git commit --no-verify
```

### Running Tests

```bash
./scripts/test.sh
```

`scripts/test.sh` auto-detects the environment:

- **With Xcode** (XCTest available): runs the full `XCTest` suite via `swift test`.
- **Headless / Command-Line-Tools only** (no `XCTest.framework`): builds and runs
  `XRadarVerifier`, an XCTest-free runner that exercises the exact same production
  logic and the full acceptance checklist (account URL parsing, keyword matching,
  first baseline, dedup across restart, scheduler re-entrancy, state persistence,
  Telegram error handling, login state machine, and the mock full chain).

Tests cover:
- **Account URL parsing** — `@handle`, `x.com`/`twitter.com` URLs, reserved paths, length/character rules, and Unicode normalization (`XHandleParserTests`)
- **Keyword matching** — include/exclude, any/all, case-sensitivity, Chinese/English, phrase matching, rule enable/account scoping (`KeywordMatcherTests`)
- **First baseline** — the first fetch only establishes a cursor and never notifies historical tweets (`MonitoringPipelineMockTests`)
- **Deduplication across restart** — tweets are de-duped by ID using a persisted `AccountCursor`, so a restart never re-notifies (`MonitoringPipelineMockTests`, `StatePersistenceTests`)
- **Scheduler re-entrancy** — only one monitoring pass is ever in flight; concurrent/manual triggers never overlap, busy-loop, or spawn duplicate timers (`SchedulerReentrancyTests`)
- **State persistence** — atomic JSON write/read, corrupt-main-file recovery from `.bak`, and cursor hand-back across scheduler runs (`StatePersistenceTests`)
- **Telegram error handling** — 200 success, 400/429/500 (with retry) and network errors all surface as a `.failure` result without crashing; local notifications are unaffected (`TelegramNotifierTests`)
- **Login state machine** — `XSessionState` helpers and `RuntimeState.status` transitions (login required / action required / degraded / backing off / paused) (`LoginStateMachineTests`)
- **Mock full chain** — scheduler → pipeline → repository → derived status, with login-required / rate-limited / action-required propagated end-to-end using mocks (`MockFullChainTests`)

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

XRadar is an independent, unofficial project and is not affiliated with,
endorsed by, or sponsored by X Corp. It is not built on the official X API; it
reads publicly reachable pages through a WebView or an RSSHub instance you
configure yourself. Use it in accordance with X's Terms of Service. "X" and
"Twitter" are trademarks of their respective owners.

## Support

For issues, questions, or contributions, please open an issue or pull request
on the project repository. See [CONTRIBUTING.md](CONTRIBUTING.md).
