# XRadar Agent Development Guide

## Overview

This document provides guidance for AI agents working on the XRadar codebase.

## Architecture Principles

### Module Layout

The codebase is split into two Swift Package Manager modules:

- **`Sources/XRadarCore/`** — SwiftUI-free core logic (models, rules, timeline,
  notifications, persistence, security, scheduling, pipeline, session, utilities).
  Kept free of `SwiftUI`/`SwiftUICore` so it can be unit-tested and run headless
  (the macOS 26 SDK forbids CLI tools from linking `SwiftUICore`).
- **`XRadar/`** — the SwiftUI application (`App` + `UI` views). Depends on
  `XRadarCore` and imports it with `@testable import XRadarCore` (the core is
  built with `-enable-testing`).
- **`XRadarVerifier/`** — an XCTest-free headless verification runner that
  exercises the core via `@testable import XRadarCore`. Used in environments
  without `XCTest.framework` (e.g. Command-Line-Tools-only installs).
- **`XRadarTests/`** — the `XCTest` suite; requires Xcode.app / XCTest.framework.

When adding or moving code, keep SwiftUI imports out of `XRadarCore`.

### Actor-Based Concurrency

XRadar uses Swift actors for thread safety:

- `AppModel`: `@MainActor` for UI state
- `PollScheduler`: `actor` for scheduling
- `MonitoringPipeline`: `actor` for processing
- Repositories: `@MainActor` for persistence

### Protocol-Oriented Design

Key protocols for extensibility:

- `TimelineProvider`: Abstracts tweet fetching (WebView now, API later)
- `NotificationChannel`: Abstracts notifications (macOS, Telegram)
- `RuleEvaluating`: Abstracts rule evaluation

### Data Isolation

- **Never expose cookies**: XSession manages WebKit, business logic never sees cookies
- **Keychain for secrets**: Telegram credentials only in Keychain
- **JSON for config**: No secrets in JSON files
- **No HTML logging**: Don't log full page content

## Adding Features

### New Notification Channel

1. Conform to `NotificationChannel` protocol
2. Implement `send()` and `sendTest()`
3. Add to `NotificationGateway` channels array
4. Add to `NotificationChannelID` enum
5. Add UI in `NotificationsSettingsView`

### New Rule Type

1. Extend `TriggerMode` enum
2. Update `RuleEngine.evaluate()`
3. Add UI controls in `RuleEditorView`
4. Update persistence schema version if needed

### New Data Source

1. Implement `TimelineProvider` protocol
2. Add configuration option in `AppConfiguration`
3. Create factory method to select provider
4. Keep `XSession` for authentication

### Custom RSS Source Rules (§13 of DESIGN-RSSHUB.md)

`MonitorRule.feedURL != nil` 表示自定义 RSS 源规则（任意 http(s) RSS/Atom 订阅），
与 X 账号规则共存。要点：

- Pipeline 按 `feedURL` 分组抓取（同一 URL 只抓一次、共享 cursor），
  处理/错误分类与 X 规则共用 `processAccount` 之后的整段逻辑。
- 通用解析用 `XRSSParser.parseGeneric`（guid/link 作 ID、无日期按 now、
  三天窗口/十条截取不变）；直连抓取用 `RSSDirectFeedProvider`
  （无 Cookie、单 host 重定向、禁 x.com/twitter.com 域名）。
- feed 规则**不经过** `XTimelineRouter` / `XSourcePolicy`；只要存在已启用
  feed 规则，`PollScheduler` 的"源配置未完成"门槛就放行（约束 11 例外）。
- `KeywordMatcher` 对 feed 规则跳过账号归属校验（accountHandle 只是显示名）。
- 新增 feed 能力时同步更新 `XRadarVerifier.checkGenericRSSFeeds` 与
  `XRadarTests` 的 RSSParserTests / MonitoringPipelineMockTests 镜像测试。

## Testing Strategy

### Unit Tests

Test logic in isolation:

```swift
func testKeywordMatcher() {
    let matcher = KeywordMatcher()
    let rule = MonitorRule(...)
    let tweet = Tweet(...)
    let match = matcher.evaluate(tweet: tweet, rule: rule)
    XCTAssertNotNil(match)
}
```

### Integration Tests

Test with real dependencies but mocked external services:

```swift
func testPipelineWithMockTimeline() {
    let mockProvider = MockTimelineProvider()
    let pipeline = MonitoringPipeline(..., timelineProvider: mockProvider)
    // Test full pipeline flow
}
```

### Fixture Tests

Use HTML fixtures for DOM extraction tests:

```swift
func testExtractTweetsFromFixture() async {
    let html = loadFixture("profile_originals.html")
    let tweets = await extractor.extract(from: html)
    XCTAssertEqual(tweets.count, 3)
}
```

## Code Style

- **Swift 6** with strict concurrency
- **Explicit self**: Always use `self.` for clarity
- **No force unwraps**: Use `guard let` or `if let`
- **Actor isolation**: Respect MainActor and actor boundaries
- **Error handling**: Propagate errors, don't swallow them

## Common Patterns

### Async/Await

```swift
func loadData() async throws -> Data {
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let httpResponse = response as? HTTPURLResponse,
          httpResponse.statusCode == 200 else {
        throw AppError.networkUnavailable
    }
    return data
}
```

### Error Propagation

```swift
do {
    try await riskyOperation()
} catch {
    await logger.error("Operation failed: \(error)")
    state = .failed(message: error.localizedDescription)
}
```

### Publisher to Async

```swift
Timer.publish(every: 5, on: .main, in: .common)
    .autoconnect()
    .asyncMap { _ in
        await self.reloadEvents()
    }
    .sink { _ in }
    .store(in: &cancellables)
```

## Security Checklist

When modifying code, verify:

- [ ] No secrets logged (use `Logger` with privacy annotations)
- [ ] Keychain used for Telegram credentials
- [ ] No cookie values in business logic
- [ ] HTML fixtures don't contain real personal data
- [ ] Diagnostic exports redact sensitive information
- [ ] URL parameters with tokens not logged

## Debugging

### Enable Verbose Logging

```swift
// In AppModel.init()
Logger.app.logLevel = .debug
```

### Inspect WebView

```swift
// In XSession
webView.inspectable = true // For Safari Web Inspector
```

### Check Saved State

```bash
# View config
cat ~/Library/Application\ Support/XRadar/config.json | jq .

# View state
cat ~/Library/Application\ Support/XRadar/state.json | jq .

# View events
cat ~/Library/Application\ Support/XRadar/events.json | jq .
```

## Documentation

Update these files when making changes:

- `DESIGN.md`: Architecture decisions
- `README.md`: User-facing documentation
- `CHANGELOG.md`: Version history
- `AGENTS.md`: This file - agent guidance

## Resources

- [Swift Concurrency](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html)
- [SwiftUI App Protocol](https://developer.apple.com/documentation/swiftui/app)
- [WKWebView Documentation](https://developer.apple.com/documentation/webkit/wkwebview)
- [User Notifications](https://developer.apple.com/documentation/usernotifications)
