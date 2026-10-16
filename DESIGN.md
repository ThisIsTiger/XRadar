# XRadar：macOS 菜单栏 X 账号关键词监控工具开发方案

> 文档状态：MVP 实施规格（历史设计文档）
> 目标读者：可直接修改本地仓库、运行构建和测试命令的编码型 AI Agent
> 临时产品名：`XRadar`，所有命名集中管理，后续可整体替换

> **实现说明（与本文原始的差异）**：仓库实际以 **Swift Package Manager** 构建，
> 不使用、也不提交 `.xcodeproj`（本文下方出现的 Xcode 工程 / `xcodebuild`
> 内容为最初规划，已不适用）。核心逻辑拆分到 SwiftUI-free 的
> `Sources/XRadarCore` 模块，App 在 `XRadar/`，并以
> `XRadarVerifier`（无 XCTest 依赖）在无 Xcode 环境下做等价验收。
> 构建与验证以 `scripts/` 下的脚本为准。

> **RSSHub 信源改造规格见 [`DESIGN-RSSHUB.md`](./DESIGN-RSSHUB.md)（§1-§15）**。
> 它以 `XTimelineRouter` 引入双 `TimelineProvider`（RSSHub 与 X WebView），
> 并定义了信源策略、Cursor/去重语义、调度抖动与 backoff、失败回退与 UI 规格。

---

## 1. 产品目标

构建一个轻量、纯本地运行的 macOS 菜单栏应用。用户在应用内部通过真实的 X 网页完成一次登录，配置要监控的 X 账号、抓取频率和关键词规则。应用定时访问目标账号页面，提取新推文；当推文命中关键词规则时，通过 macOS 系统通知和可选的 Telegram Bot 发出提醒。

核心链路：

```text
应用内登录 X
    ↓
定时访问指定账号页面
    ↓
提取最新推文
    ↓
本地去重
    ↓
关键词规则匹配
    ↓
生成统一事件
    ↓
macOS 通知 + Telegram Bot
```

### 1.1 MVP 必须实现

1. macOS 菜单栏常驻。
2. 应用内 `WKWebView` 登录 X，并持久保存应用自己的独立登录态。
3. 添加、编辑、启用、暂停、删除监控规则。
4. 监控目标支持：
   - `@elonmusk`
   - `elonmusk`
   - `https://x.com/elonmusk`
   - `https://twitter.com/elonmusk`
5. 全局抓取频率：1、5、10、30、60 分钟，默认 5 分钟。
6. 关键词触发：
   - 任意关键词命中。
   - 全部关键词命中。
   - 排除关键词。
   - 默认忽略大小写、全角半角和变音差异。
   - 支持中文、英文和短语。
7. 可选“所有新推文都通知”，不要求填写关键词。
8. 本地文件持久化配置、游标、已见推文和最近事件，不使用数据库。
9. macOS 原生通知；点击通知打开原推文。
10. 可选 Telegram Bot 通知；支持测试通知。
11. 菜单栏显示运行状态、未读数量、下次检查时间、最近事件和“立即检查”。
12. 登录失效、网页异常、疑似挑战页、通知失败时有明确状态，不进行无限重试。
13. 单元测试、HTML Fixture 解析测试、通知请求测试和完整 Mock 流程测试。

### 1.2 MVP 不实现

- 不调用 LLM，不做语义匹配或摘要。
- 不读取 Safari、Chrome 或其他浏览器的 Cookie。
- 不导入、导出或明文保存 X Cookie。
- 不接入 SQLite、Core Data、服务端数据库或消息队列。
- 不开发浏览器扩展。
- 不开发 iOS App、Web 后台或远程账户系统。
- 不绕过 CAPTCHA、挑战页、频率限制或其他访问控制。
- 不调用、复刻或逆向 X 的私有 GraphQL/内部接口。
- 不模拟点赞、转发、关注、发帖等写操作。
- 不自动更新应用。

---

## 2. 重要风险与实现边界

X 当前服务条款明确限制未经许可的自动抓取。因此 `WebViewTimelineProvider` 必须被视为“个人、本地、实验性数据源”，不能设计任何规避检测、突破挑战页或绕过技术限制的逻辑。应用发现登录、挑战或访问限制问题时必须停止抓取并要求用户在可见登录窗口中处理。

代码必须通过 `TimelineProvider` 协议隔离数据源，使未来可以替换为官方 X API，而不改变调度、规则、持久化和通知层。

应用首次启用 WebView 数据源时显示一次说明：

```text
此模式通过你在应用内登录后看到的 X 网页读取公开推文。
X 的页面结构和使用规则可能变化，功能可能失效。
本应用不会绕过登录验证或访问限制。
```

用户确认结果只保存在本地配置中。

---

## 3. 技术约束

### 3.1 平台

- macOS 13.0 及以上。
- 同时支持 Intel `x86_64` 和 Apple Silicon `arm64`。
- Xcode 当前稳定版本。
- Swift 6 语言模式优先；如第三方工具链限制，可使用 Swift 5 语言模式并保持严格并发检查。

选择 macOS 13 的原因：

- 使用 SwiftUI `MenuBarExtra`。
- 使用 `SMAppService.mainApp` 实现“登录时启动”。
- 保持代码量和运行时依赖最小。

### 3.2 框架

```text
SwiftUI
AppKit
WebKit
UserNotifications
ServiceManagement
Security / Keychain Services
OSLog
Foundation
```

不引入第三方运行时依赖。构建使用 Swift Package Manager（`Package.swift`），不引入 `.xcodeproj` 之类的生成工程。

### 3.3 应用形态

- `LSUIElement = true`，默认不显示 Dock 图标。
- 主入口为 `MenuBarExtra`，使用 `.window` 风格展示 SwiftUI 弹窗。
- 设置、登录和诊断使用独立 SwiftUI Window。
- 应用在菜单栏运行期间执行调度；Mac 睡眠期间不抓取，唤醒后立即执行一次补偿检查。

---

## 4. 用户体验规格

## 4.1 首次启动

1. 请求 macOS 通知权限。
2. 显示菜单栏图标。
3. 菜单弹窗显示“尚未连接 X”。
4. 用户点击“登录 X”。
5. 打开独立登录窗口，加载 `https://x.com/i/flow/login`。
6. 用户直接在 X 页面登录；应用不读取输入框内容。
7. 登录完成后应用验证会话，显示当前账号或“已登录”。
8. 用户添加第一条监控规则。
9. 首次抓取仅建立基线，默认不通知历史推文。

## 4.2 菜单栏弹窗

建议尺寸：宽 360 pt，高度 420–560 pt 自适应。

```text
┌──────────────────────────────────┐
│ XRadar                      ● 2  │
│ 运行中 · 2 个账号                 │
│ 下次检查：3 分钟后                 │
├──────────────────────────────────┤
│ [立即检查] [暂停]                  │
├──────────────────────────────────┤
│ 最近事件                          │
│ @elonmusk · 2 分钟前               │
│ 命中：Starship, launch            │
│ SpaceX plans another ...          │
│                                  │
│ @sama · 18 分钟前                 │
│ 命中：GPT-6                       │
│ ...                              │
├──────────────────────────────────┤
│ 登录状态   监控规则   设置   退出   │
└──────────────────────────────────┘
```

必须显示的状态：

- `运行中`
- `暂停`
- `正在检查`
- `需要登录`
- `需要用户处理 X 验证`
- `网络异常`
- `已退避至 HH:mm`

## 4.3 设置窗口

使用 TabView，固定最小尺寸约 760 × 540 pt。

### Tab A：X 账号

- 登录状态。
- 当前登录账号；无法可靠解析账号时显示“已登录”。
- 上次成功验证时间。
- `登录 X`、`打开 X`、`重新登录`、`退出登录`。
- “退出登录”必须先确认，并清理应用 WebKit 数据容器中的 X 数据。

### Tab B：监控规则

左侧规则列表，右侧编辑器。

每条规则字段：

- 规则名称，可自动生成，允许编辑。
- X 账号/链接。
- 启用开关。
- 触发模式：
  - 所有新推文。
  - 关键词触发。
- 正向关键词标签列表。
- 排除关键词标签列表。
- 匹配模式：任意 / 全部。
- 区分大小写，默认关闭。
- 包含转发，默认关闭。
- 包含回复，默认关闭。
- 通知渠道：macOS、Telegram，可单独开关。

关键词编辑器：

- Enter、逗号或换行提交关键词。
- 自动 Trim。
- 空字符串不保存。
- 同一规则内去重。
- 单关键词最大 100 字符。
- 每组最多 50 个关键词。

### Tab C：抓取

- 检查频率 Picker：1、5、10、30、60 分钟。
- 启动应用时立即检查：默认开启。
- Mac 唤醒后立即检查：默认开启。
- 手动“立即检查”。
- 显示上次检查、下次检查和最近一次耗时。

### Tab D：通知

macOS：

- 开关。
- 声音开关。
- `发送测试通知`。
- 权限状态。
- `打开系统通知设置`。

Telegram：

- 开关。
- Bot Token：SecureField，存 Keychain。
- Chat ID：SecureField 或 TextField，存 Keychain。
- `验证并发送测试消息`。
- 显示最近一次发送成功/失败时间。

### Tab E：通用与诊断

- 登录时启动，使用 `SMAppService.mainApp`。
- 历史保留：7、30、90 天，默认 30 天。
- 最近事件上限：100、500、1000，默认 500。
- 导出诊断日志。
- 清除事件历史。
- 重置应用，不删除系统钥匙串前需明确确认。

---

## 5. 总体架构

```text
┌─────────────────────────────────────────────────────┐
│ UI Layer                                            │
│ MenuBar / Settings / Login / Event Detail           │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│ AppModel / Application Coordinator                  │
└───────┬───────────────┬───────────────┬─────────────┘
        │               │               │
┌───────▼──────┐ ┌──────▼──────┐ ┌─────▼────────────┐
│ PollScheduler│ │ XSession     │ │ RuleEngine       │
│              │ │ WKWebView    │ │ KeywordMatcher   │
└───────┬──────┘ └──────┬──────┘ └─────┬────────────┘
        │               │              │
        └───────┬───────┘              │
                ▼                      │
        ┌───────────────┐              │
        │TimelineProvider│─────────────┘
        │ WebView MVP    │
        │ Official API ∅ │
        └───────┬───────┘
                ▼
        ┌───────────────┐
        │ Event Pipeline │
        └───────┬───────┘
                ▼
┌─────────────────────────────────────────────────────┐
│ NotificationGateway                                │
│ macOSLocalNotifier / TelegramNotifier              │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│ Persistence & Security                              │
│ JSONFileStore / WebKit Data Store / Keychain / Log │
└─────────────────────────────────────────────────────┘
```

原则：

1. UI 不直接调用 WebKit、文件系统或 Telegram。
2. `XSession` 是唯一可以接触应用内部 X WebKit 会话的模块。
3. 业务层不能拿到 Cookie 值。
4. 同一个账号只抓取一次，再对关联规则逐条匹配。
5. 通知模块只接收统一的 `NotificationEvent`。
6. 所有选择器集中在一个文件，X 页面变化时只改一个区域。

---

## 6. 项目目录

```text
XRadar/
├── Package.swift
├── Sources/XRadarCore/
├── XRadar/
├── XRadarVerifier/
├── XRadarTests/
├── scripts/
├── DESIGN.md
├── AGENTS.md
├── README.md
├── CHANGELOG.md
├── PROGRESS.md
├── FINAL_REPORT.md
├── scripts/
│   ├── bootstrap.sh
│   ├── build.sh
│   ├── test.sh
│   ├── verify.sh
│   └── package.sh
├── XRadar/
│   ├── App/
│   │   ├── XRadarApp.swift
│   │   ├── AppModel.swift
│   │   ├── AppCoordinator.swift
│   │   └── AppEnvironment.swift
│   ├── Models/
│   │   ├── MonitorRule.swift
│   │   ├── Tweet.swift
│   │   ├── NotificationEvent.swift
│   │   ├── AppConfiguration.swift
│   │   ├── RuntimeState.swift
│   │   └── AppError.swift
│   ├── Session/
│   │   ├── XSession.swift
│   │   ├── XSessionState.swift
│   │   ├── SessionProbe.swift
│   │   └── WebViewContainer.swift
│   ├── Timeline/
│   │   ├── TimelineProvider.swift
│   │   ├── WebViewTimelineProvider.swift
│   │   ├── TimelineRequest.swift
│   │   ├── TweetDOMDecoder.swift
│   │   └── XDOMSelectors.swift
│   ├── Resources/
│   │   ├── Scripts/extract_tweets.js
│   │   ├── Fixtures/profile_originals.html
│   │   ├── Fixtures/profile_repost.html
│   │   ├── Fixtures/profile_empty.html
│   │   └── Assets.xcassets
│   ├── Rules/
│   │   ├── RuleEngine.swift
│   │   ├── KeywordMatcher.swift
│   │   └── KeywordNormalizer.swift
│   ├── Scheduling/
│   │   ├── PollScheduler.swift
│   │   ├── PollingInterval.swift
│   │   └── WakeObserver.swift
│   ├── Pipeline/
│   │   ├── MonitoringPipeline.swift
│   │   └── EventBuilder.swift
│   ├── Notifications/
│   │   ├── NotificationChannel.swift
│   │   ├── NotificationGateway.swift
│   │   ├── MacOSLocalNotifier.swift
│   │   ├── TelegramNotifier.swift
│   │   └── TelegramMessageFormatter.swift
│   ├── Persistence/
│   │   ├── JSONFileStore.swift
│   │   ├── ConfigurationRepository.swift
│   │   ├── StateRepository.swift
│   │   ├── EventRepository.swift
│   │   └── AtomicFileWriter.swift
│   ├── Security/
│   │   └── KeychainStore.swift
│   ├── Diagnostics/
│   │   ├── AppLogger.swift
│   │   └── DiagnosticsExporter.swift
│   ├── UI/
│   │   ├── MenuBar/
│   │   ├── Login/
│   │   ├── Settings/
│   │   ├── Rules/
│   │   ├── Events/
│   │   └── Components/
│   └── Utilities/
│       ├── XHandleParser.swift
│       ├── DateFormatting.swift
│       └── CollectionExtensions.swift
├── XRadarTests/
│   ├── XHandleParserTests.swift
│   ├── KeywordMatcherTests.swift
│   ├── RuleEngineTests.swift
│   ├── JSONFileStoreTests.swift
│   ├── EventCleanupTests.swift
│   ├── TelegramNotifierTests.swift
│   ├── TweetDOMDecoderTests.swift
│   └── MonitoringPipelineTests.swift
└── XRadarUITests/
    └── XRadarLaunchTests.swift
```

---

## 7. 核心数据模型

所有持久化模型必须 `Codable`、可迁移，并包含 `schemaVersion`。

```swift
struct MonitorRule: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var accountHandle: String
    var enabled: Bool
    var triggerMode: TriggerMode
    var includeKeywords: [String]
    var excludeKeywords: [String]
    var keywordMatchMode: KeywordMatchMode
    var caseSensitive: Bool
    var includeReplies: Bool
    var includeReposts: Bool
    var notificationChannels: Set<NotificationChannelID>
    var createdAt: Date
    var updatedAt: Date
}

enum TriggerMode: String, Codable, Sendable {
    case allNewTweets
    case keywords
}

enum KeywordMatchMode: String, Codable, Sendable {
    case any
    case all
}

enum NotificationChannelID: String, Codable, Hashable, Sendable {
    case macOS
    case telegram
}
```

```swift
struct Tweet: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let authorHandle: String
    let text: String
    let url: URL
    let publishedAt: Date?
    let kind: TweetKind
    let isPinned: Bool
}

enum TweetKind: String, Codable, Sendable {
    case original
    case reply
    case repost
    case unknown
}
```

```swift
struct RuleMatch: Equatable, Sendable {
    let ruleID: UUID
    let matchedKeywords: [String]
    let reason: MatchReason
}

enum MatchReason: Equatable, Sendable {
    case allNewTweets
    case keywordAny
    case keywordAll
}
```

```swift
struct NotificationEvent: Codable, Identifiable, Equatable, Sendable {
    let id: String                 // "tweet:<tweetID>"
    let tweetID: String
    let authorHandle: String
    let title: String
    let body: String
    let tweetURL: URL
    let matchedRuleIDs: [UUID]
    let matchedKeywords: [String]
    let createdAt: Date
    var readAt: Date?
    var channelResults: [NotificationChannelID: DeliveryResult]
}
```

```swift
struct AccountCursor: Codable, Equatable, Sendable {
    var seenTweetIDs: [String]
    var initialized: Bool
    var lastCheckedAt: Date?
    var lastSuccessfulFetchAt: Date?
    var lastErrorCode: String?
}
```

`seenTweetIDs` 使用顺序数组而非 Set 持久化，读取后转换成 Set。每个账号最多保留 300 个 ID，写回时裁剪。

---

## 8. 本地持久化

目录：

```text
~/Library/Application Support/XRadar/
├── config.json
├── state.json
├── events.json
└── logs/
```

敏感信息：

```text
WebKit Data Store：X 登录 Cookie、Local Storage 等
macOS Keychain：Telegram Bot Token、Telegram Chat ID
```

### 8.1 `config.json`

```json
{
  "schemaVersion": 1,
  "pollIntervalSeconds": 300,
  "runCheckAtLaunch": true,
  "runCheckAfterWake": true,
  "launchAtLogin": false,
  "historyRetentionDays": 30,
  "maxRecentEvents": 500,
  "webViewProviderAcknowledged": true,
  "macOSNotificationsEnabled": true,
  "macOSNotificationSoundEnabled": true,
  "telegramEnabled": false,
  "rules": []
}
```

### 8.2 `state.json`

```json
{
  "schemaVersion": 1,
  "isPaused": false,
  "backoffUntil": null,
  "accounts": {
    "elonmusk": {
      "seenTweetIDs": ["123", "122"],
      "initialized": true,
      "lastCheckedAt": "2026-07-22T16:00:00Z",
      "lastSuccessfulFetchAt": "2026-07-22T16:00:00Z",
      "lastErrorCode": null
    }
  }
}
```

### 8.3 `events.json`

```json
{
  "schemaVersion": 1,
  "events": []
}
```

### 8.4 写入规则

所有 JSON 更新必须：

1. 编码到同目录临时文件。
2. `FileHandle.synchronize()` 或等效方式刷新。
3. 使用原子替换覆盖目标文件。
4. 保留上一份 `.bak`，仅保留一份。
5. 读取失败时尝试 `.bak`。
6. 两份都失败时创建默认数据并显示诊断错误，不崩溃。

清理时机：

- 应用启动。
- 每次成功检查完成后，最多每 6 小时执行一次。
- 用户手动清理。

---

## 9. X 登录会话设计

## 9.1 `XSession`

```swift
@MainActor
protocol XSessionProtocol: AnyObject {
    var state: XSessionState { get }
    func presentLogin() async
    func validateSession() async -> XSessionState
    func makeAuthenticatedWebView() -> WKWebView
    func logout() async throws
}
```

实际类必须是 `@MainActor final class XSession`，因为 `WKWebView` 受主线程约束。

### 9.2 数据容器

- 使用 `WKWebsiteDataStore.default()`。
- 这是应用自己的 WebKit 持久数据，不共享 Safari/Chrome 登录态。
- 不把 Cookie 值复制到 Swift 模型、日志或 JSON。
- `SessionProbe` 可以在 `XSession` 内部检查必要 Cookie 的“存在性”，但禁止记录 Cookie 名值对。

### 9.3 登录窗口

- 显示真实地址栏样式的只读 Host 标识。
- 初始 URL：`https://x.com/i/flow/login`。
- 允许 HTTPS 导航以兼容 X 自身登录、Google/Apple 登录和验证流程。
- 禁止 `file://`、自定义 Scheme 和非 HTTPS 顶层导航；外部普通链接交给默认浏览器。
- 不注入读取表单、密码或输入内容的 JavaScript。

### 9.4 登录验证

`validateSession()`：

1. 在同一数据容器的新 `WKWebView` 中加载 `https://x.com/home`。
2. 等待导航完成或 15 秒超时。
3. 若跳转到登录流程，状态为 `.loggedOut`。
4. 若出现 challenge/account access 页面，状态为 `.actionRequired`。
5. 若页面出现主导航或用户 Profile 链接，状态为 `.loggedIn(handle: String?)`。
6. DOM 不确定但必要登录 Cookie 存在时，状态可为 `.probablyLoggedIn`，随后由第一次时间线请求验证。

```swift
enum XSessionState: Equatable, Sendable {
    case unknown
    case loggedOut
    case validating
    case loggedIn(handle: String?)
    case probablyLoggedIn
    case actionRequired(message: String)
    case failed(message: String)
}
```

### 9.5 退出登录

- 调用 `WKWebsiteDataStore` 清理全部 WebKit website data。
- 清理后重新验证为 `.loggedOut`。
- 不删除监控规则和历史事件。
- “重置应用”才同时清理 WebKit、配置、状态、事件和 Keychain。

---

## 10. 时间线抓取设计

## 10.1 协议

```swift
protocol TimelineProvider: Sendable {
    func fetch(_ request: TimelineRequest) async throws -> [Tweet]
}

struct TimelineRequest: Equatable, Sendable {
    let accountHandle: String
    let includeReplies: Bool
    let maximumCount: Int
}
```

MVP 实现：

```swift
final class WebViewTimelineProvider: TimelineProvider
```

未来实现但本期不做：

```swift
final class OfficialXAPITimelineProvider: TimelineProvider
```

## 10.2 页面 URL

```text
不含回复：https://x.com/{handle}
包含回复：https://x.com/{handle}/with_replies
```

每个账号在一次轮询中：

- 若所有规则都不包含回复，只请求普通 Profile。
- 若所有规则都包含回复，只请求 `with_replies`。
- 若两类规则同时存在，允许请求两次；结果按 Tweet ID 合并。
- 请求必须串行，禁止并发加载多个账号页面。

## 10.3 加载流程

1. 使用与登录窗口相同 `WKWebsiteDataStore` 的专用隐藏 `WKWebView`。
2. 加载目标页面。
3. 导航完成后，每 500ms 检查一次是否出现推文 Article，最多等待 12 秒。
4. 执行固定的本地 `extract_tweets.js`。
5. JavaScript 只返回 JSON 兼容对象，不发起额外网络请求。
6. Swift 解码为 `[RawTweetDOMRecord]`，再转换为 `[Tweet]`。
7. 最多返回页面中前 20 条。

## 10.4 选择器集中化

`XDOMSelectors.swift` 只保存选择器和页面状态特征：

```swift
enum XDOMSelectors {
    static let tweetArticle = "article[data-testid='tweet']"
    static let tweetText = "[data-testid='tweetText']"
    static let timestamp = "time[datetime]"
    static let socialContext = "[data-testid='socialContext']"
    static let profileLink = "a[data-testid='AppTabBar_Profile_Link']"
}
```

`extract_tweets.js` 不允许散落魔法字符串；构建时由 Swift 注入选择器，或在 JS 顶部集中声明。

## 10.5 JavaScript 返回契约

```json
[
  {
    "id": "123456789",
    "url": "https://x.com/elonmusk/status/123456789",
    "authorHandle": "elonmusk",
    "text": "Example tweet",
    "publishedAt": "2026-07-22T15:20:00.000Z",
    "isPinned": false,
    "hasSocialContext": false,
    "replyingToText": null
  }
]
```

提取要求：

- Tweet ID 必须来自 `/status/{id}` 链接。
- 没有合法 ID 或 URL 的 Article 丢弃。
- Tweet 正文可以为空，例如仅图片推文；空正文不会命中关键词，但在“所有新推文”模式可通知。
- 对同一 ID 去重。
- DOM 解码失败不导致整页失败，应丢弃单条并记录计数。

## 10.6 推文类型

尽力识别，不保证完全准确：

- `socialContext` 表示转发时标记 `.repost`。
- 可识别“Replying to”或相关结构时标记 `.reply`。
- 其他为 `.original`。
- 结构不确定为 `.unknown`。

规则过滤：

- `.repost` 仅在 `includeReposts = true` 时匹配。
- `.reply` 仅在 `includeReplies = true` 时匹配。
- `.unknown` 默认按 `.original` 处理，避免漏掉正常推文。

## 10.7 页面状态检测

以下情况不得继续重试：

- URL 回到登录流程：抛出 `.authenticationRequired`。
- Challenge、Account Access、验证码：抛出 `.userActionRequired`。
- 明显限流/访问限制：抛出 `.rateLimited(retryAfter:)`。

不实现 CAPTCHA 识别或自动处理。

临时错误：

- 无网络。
- DNS/连接失败。
- 页面加载超时。
- DOM 暂时为空。

临时错误最多即时重试 1 次，延迟 10 秒。

---

## 11. 账号输入解析

```swift
enum XHandleParser {
    static func parse(_ input: String) throws -> String
}
```

规则：

1. Trim 空格和换行。
2. 去掉开头 `@`。
3. URL 仅接受 `x.com`、`www.x.com`、`twitter.com`、`www.twitter.com`。
4. 取第一个 path component 作为 Handle。
5. 排除保留路径：`home`、`explore`、`notifications`、`messages`、`i`、`search`、`settings`、`compose`。
6. Handle 仅允许 `[A-Za-z0-9_]`，长度 1–15。
7. 统一保存小写 Handle，但 UI 可显示用户原始大小写。

必须有完整单元测试。

---

## 12. 关键词规则引擎

## 12.1 协议

```swift
protocol RuleEvaluating: Sendable {
    func evaluate(tweet: Tweet, rule: MonitorRule) -> RuleMatch?
}
```

## 12.2 标准化

当 `caseSensitive = false`：

1. Unicode Canonical Normalization。
2. Case folding。
3. Width insensitive。
4. Diacritic insensitive。
5. 不进行分词，不删除标点。

匹配方式是“子字符串匹配”，因此：

- `Starship launch` 可作为完整短语。
- `AI` 会匹配 `AI`、`ai`，也可能匹配更长字符串；MVP 不提供单词边界模式。
- 中文直接进行 Unicode 子字符串匹配。

## 12.3 逻辑

```text
规则未启用 → 不匹配
账号不同 → 不匹配
推文类型被排除 → 不匹配
命中任一排除关键词 → 不匹配
triggerMode = allNewTweets → 匹配
triggerMode = keywords 且正向关键词为空 → 配置无效，不匹配
matchMode = any 且至少一个正向关键词命中 → 匹配
matchMode = all 且所有正向关键词命中 → 匹配
否则 → 不匹配
```

返回原始关键词而非标准化关键词，用于通知展示。

## 12.4 多规则聚合

同一推文命中多个规则时：

- 只生成一条 `NotificationEvent`。
- `matchedRuleIDs` 包含全部规则。
- `matchedKeywords` 去重后合并。
- 通知渠道取所有命中规则渠道的并集。

避免同一推文连续弹出多条通知。

---

## 13. 去重与首次基线

每个账号独立维护 `AccountCursor`。

### 13.1 首次抓取

若 `initialized = false`：

1. 抓取当前最多 20 条推文。
2. 全部加入 `seenTweetIDs`。
3. 设置 `initialized = true`。
4. 不产生通知。
5. UI 显示“已建立监控基线”。

### 13.2 后续抓取

1. 过滤 `seenTweetIDs`。
2. 新推文按时间或页面顺序从旧到新处理。
3. 规则匹配、发送通知。
4. 无论是否命中，都写入 `seenTweetIDs`。
5. 每账号最多保留最近 300 个 Tweet ID。

### 13.3 删除并重新添加规则

- 账号 Cursor 默认保留，避免重新通知旧推文。
- 设置中提供“重置该账号基线”高级操作，需二次确认。

---

## 14. 调度器

```swift
actor PollScheduler {
    func start()
    func stop()
    func restart(interval: Duration)
    func triggerNow(reason: TriggerReason) async
}
```

行为：

- 使用可取消的 `Task` 循环，不使用 `Timer` 作为核心调度。
- 同一时间最多有一次 Pipeline 运行。
- 手动检查发生在运行中时，不启动第二次；设置一个 `runAgainAfterCurrent` 标志。
- 修改频率立即取消旧循环并重建。
- 应用暂停时停止循环，但保留配置。
- 启动检查和唤醒检查受配置开关控制。
- 通过 `NSWorkspace.shared.notificationCenter` 监听 `didWakeNotification`。
- Mac 睡眠期间不承诺执行。

退避：

- 认证失败：停止自动检查，直到用户重新登录。
- 用户操作要求：停止自动检查，菜单栏高亮。
- 限流或访问限制：默认退避 30 分钟，使用解析到的 retry time 时优先。
- 普通网络错误：保留下次正常调度，不全局退避。

---

## 15. 监控 Pipeline

```swift
actor MonitoringPipeline {
    func run(reason: TriggerReason) async -> PollRunSummary
}
```

准确流程：

1. 若暂停、退避未结束或没有启用规则，返回对应状态。
2. 调用 `XSession.validateSession()`。
3. 按 `accountHandle` 分组启用规则。
4. 对账号串行执行：
   - 根据规则决定请求普通 Profile、with_replies 或两者。
   - 合并并去重 Tweet。
   - 首次运行建立基线。
   - 过滤已见 Tweet。
   - 对每条 Tweet 逐规则评估。
   - 聚合成 `NotificationEvent`。
   - 写入事件历史。
   - 调用 NotificationGateway。
   - 更新 Cursor。
5. 原子写入 State 和 Events。
6. 更新 UI 的运行摘要。
7. 执行有频率限制的历史清理。

账号间延迟固定 1 秒，仅用于避免瞬时页面负载，不作为规避检测手段。

失败隔离：

- 单个账号临时失败不阻断其他账号。
- 认证失效、挑战或全局限流立即停止剩余账号。
- 单个通知渠道失败不影响其他渠道。

---

## 16. 通知系统

## 16.1 协议

```swift
protocol NotificationChannel: Sendable {
    var id: NotificationChannelID { get }
    func send(_ event: NotificationEvent) async -> DeliveryResult
    func sendTest() async -> DeliveryResult
}
```

```swift
actor NotificationGateway {
    func deliver(
        event: NotificationEvent,
        through channels: Set<NotificationChannelID>
    ) async -> [NotificationChannelID: DeliveryResult]
}
```

每个渠道独立执行，最多重试一次。成功渠道不得因其他渠道失败而重复发送。

## 16.2 macOS 通知

使用 `UNUserNotificationCenter`：

- 首次启动请求 `.alert`、`.sound` 权限。
- 注册 Category：`XRADAR_TWEET`。
- 注册 Action：`OPEN_TWEET`。
- 通知 `userInfo` 只保存 Tweet URL 和 Event ID。
- 用户点击通知或 Action 时使用 `NSWorkspace.shared.open(tweetURL)`。
- 应用当前活跃时也显示 Banner。

通知格式：

```text
标题：@elonmusk · 关键词触发
正文：命中 Starship、launch｜SpaceX plans another Starship launch…
```

要求：

- Title 最大约 80 字符。
- Body 最大约 220 字符，超出截断并加省略号。
- 没有正文的媒体推文显示“发布了一条媒体推文”。

## 16.3 Telegram Bot

调用：

```text
POST https://api.telegram.org/bot{BOT_TOKEN}/sendMessage
```

使用 JSON Body：

```json
{
  "chat_id": "...",
  "text": "...",
  "parse_mode": "HTML",
  "disable_web_page_preview": true,
  "reply_markup": {
    "inline_keyboard": [[
      {"text": "查看原推文", "url": "https://x.com/.../status/..."}
    ]]
  }
}
```

安全要求：

- Bot Token 和 Chat ID 从 Keychain 读取。
- 日志不得输出完整 URL、Header 或响应中可能包含的 Token。
- 请求超时 10 秒。
- HTTP 429 按 `retry_after` 最多重试一次。
- 其他 5xx 延迟 2 秒重试一次。
- 4xx 除 429 外不重试，UI 显示配置错误。
- HTML 特殊字符必须转义。

测试通知不依赖 X 登录。

---

## 17. 应用状态与错误模型

```swift
enum AppRunStatus: Equatable, Sendable {
    case idle(nextRunAt: Date?)
    case running(startedAt: Date)
    case paused
    case loginRequired
    case actionRequired(String)
    case backingOff(until: Date, reason: String)
    case degraded(String)
}
```

```swift
enum AppError: Error, Equatable, Sendable {
    case invalidHandle
    case authenticationRequired
    case userActionRequired(String)
    case rateLimited(Date?)
    case pageLoadTimeout
    case pageStructureChanged
    case networkUnavailable
    case persistenceFailure(String)
    case notificationPermissionDenied
    case telegramConfigurationInvalid
    case telegramRequestFailed(statusCode: Int)
}
```

面向用户的信息和内部错误分离。日志记录稳定错误代码，不记录 Cookie、Token、用户输入密码或网页完整 HTML。

当 `pageStructureChanged` 连续出现 3 次：

- 自动暂停抓取。
- 菜单栏显示“X 页面结构可能已变化”。
- 允许用户导出脱敏诊断。
- 不尝试切换私有接口。

---

## 18. 并发模型

- `AppModel`：`@MainActor`、`ObservableObject`。
- `XSession` 和所有 `WKWebView` 操作：`@MainActor`。
- `PollScheduler`：actor。
- `MonitoringPipeline`：actor。
- JSON Repositories：actor 或单一 `PersistenceActor`。
- Keychain：actor 包装。
- Telegram 网络请求：async `URLSession`。
- 模型尽量 `Sendable`。

禁止：

- 在后台线程直接访问 `WKWebView`。
- 通过 `DispatchSemaphore` 阻塞 async 代码。
- 用 `Task.detached` 绕过 MainActor。
- 使用全局可变单例保存业务状态。

依赖通过 `AppEnvironment` 注入，测试使用 Mock。

---

## 19. 安全与隐私

1. 开启 App Sandbox。
2. 仅申请 Outgoing Network Client 权限。
3. 不读取用户浏览器目录。
4. 不申请 Full Disk Access。
5. X 登录数据只由 WebKit Data Store 管理。
6. Telegram Token 和 Chat ID 存 Keychain。
7. JSON 文件不包含秘密。
8. 默认无遥测、无分析 SDK、无远程服务器。
9. 日志使用 `Logger` 的 privacy 标注。
10. 不保存完整网页 HTML；Fixture 仅使用人工构造或脱敏样本。
11. 导出诊断前再次脱敏 URL Query、Handle 以外的个人信息和所有秘密。
12. 退出登录和重置功能必须真实清理对应数据。

Entitlements：

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

---

## 20. 测试要求

## 20.1 单元测试

至少覆盖：

### XHandleParser

- `@elonmusk`
- `elonmusk`
- X URL、Twitter URL。
- Query、尾部 `/`。
- 非法 Host。
- 保留路径。
- 非法字符和长度。

### KeywordMatcher

- 中英文。
- 大小写。
- 全角半角。
- Diacritic。
- Any / All。
- 排除词优先。
- 空关键词。
- 短语。
- 空推文正文。

### RuleEngine

- 规则开关。
- 账号匹配。
- Reply/Repost 过滤。
- allNewTweets。
- 多规则聚合。

### Persistence

- 首次创建。
- 原子覆盖。
- 主文件损坏后读取 `.bak`。
- Schema version。
- 历史按天数和数量裁剪。
- seenTweetIDs 最大 300。

### Telegram

使用自定义 `URLProtocol` Mock：

- 正确 JSON。
- HTML 转义。
- 200 成功。
- 400 不重试。
- 429 retry_after。
- 500 重试一次。
- Token 不进入日志字符串。

## 20.2 DOM Fixture 测试

使用本地 HTML Fixture 和 `WKWebView.loadHTMLString`：

- 提取原推文。
- 提取 Tweet ID、URL、正文、时间。
- Repost。
- 无正文媒体推文。
- 重复 Article 去重。
- 无推文页面返回空数组。
- 单条结构损坏不影响其他条目。

Fixture 不包含真实用户 Cookie 或私密数据。

## 20.3 Pipeline 测试

Mock：

- MockSession。
- MockTimelineProvider。
- InMemoryRepositories。
- MockNotificationChannel。

场景：

1. 首次基线不通知。
2. 新推文未命中不通知但写入 Seen。
3. 命中关键词发送一条通知。
4. 两条规则命中只发一条聚合通知。
5. macOS 成功、Telegram 失败互不影响。
6. 登录失效停止剩余账号。
7. 单个账号网络失败继续下一个账号。
8. 重复轮询不重复通知。

## 20.4 构建验证

必须通过：

```bash
./scripts/bootstrap.sh
./scripts/build.sh
./scripts/test.sh
./scripts/verify.sh
```

`verify.sh` 至少执行：

```bash
swift build --disable-sandbox -j 4                      # Debug 构建
swift build -c release --disable-sandbox -j 4           # Release 构建
./.build/debug/XRadarVerifier                           # 等价验收（无 XCTest 环境）
```

有 Xcode 时另跑 `swift test` 执行 `XRadarTests`。

若无可用 GUI 会话，自动化验收不要求真实点击系统通知或登录 X，但必须完成 Mock E2E。

---

## 21. 可观测性与诊断

使用 `OSLog.Logger` 分类：

```text
app
session
scheduler
timeline
rules
notifications
persistence
```

每次 Poll 生成 `runID`，日志包含：

- 触发原因。
- 账号数量。
- 每账号抓取条数。
- 新推文数量。
- 命中数量。
- 通知结果。
- 总耗时。

禁止记录：

- Cookie。
- Bot Token。
- Chat ID 全值。
- 登录页面表单。
- 未经脱敏的完整网页源码。

诊断导出：

```text
XRadar-Diagnostics-YYYYMMDD-HHmmss.zip
├── app-info.json
├── redacted-config.json
├── redacted-state.json
└── recent.log
```

---

## 22. 构建、签名与分发

MVP 以本地开发运行和 Ad Hoc 打包为目标。

### 22.1 Debug

- `CODE_SIGNING_ALLOWED=NO` 用于纯构建和单元测试。
- 需要测试 UserNotifications、Keychain、Launch at Login 时，使用 Xcode 自动签名运行。

### 22.2 Package

`scripts/package.sh`：

1. Release Archive 或 Release Build。
2. 优先使用本机可用签名；没有 Developer ID 时使用 Ad Hoc 签名。
3. 输出：

```text
dist/XRadar.app
dist/XRadar-macOS.zip
```

不要求 App Store、Notarization 或自动更新。

---

## 23. 实施顺序

编码 Agent 必须按以下顺序实施，每个阶段完成后运行相关测试并更新 `PROGRESS.md`。

### Phase 0：仓库与工程

- 初始化 Git。
- 创建 Xcode 工程和目录。
- 配置 Sandbox、LSUIElement、Assets、测试 Targets。
- 创建构建脚本。

### Phase 1：模型与持久化

- 数据模型。
- Handle Parser。
- Atomic JSON Store。
- Config/State/Event Repositories。
- Keychain Store。
- 单元测试。

### Phase 2：规则引擎

- Normalizer。
- Matcher。
- Rule Engine。
- 多规则聚合。
- 单元测试。

### Phase 3：通知

- macOS Local Notifier。
- Telegram Notifier。
- 测试通知 UI。
- URLProtocol Mock Tests。

### Phase 4：X Session

- 登录窗口。
- WebKit 持久会话。
- Session Probe。
- Logout 清理。
- Mock 测试和状态 UI。

### Phase 5：Timeline Provider

- Hidden WebView。
- 页面加载状态机。
- JS Extractor。
- Fixture Tests。
- Challenge/登录/限流检测。

### Phase 6：Pipeline 与 Scheduler

- 去重和首次基线。
- Poll Scheduler。
- Wake Observer。
- Backoff。
- Mock E2E Tests。

### Phase 7：完整 UI

- Menu Bar Popover。
- Settings Tabs。
- Rule Editor 和 Keyword Tag Editor。
- Recent Events。
- 状态和错误展示。
- Launch at Login。

### Phase 8：稳定性与交付

- 全量测试。
- 静态检查和 Warning 清理。
- README。
- 诊断导出。
- Release Package。
- `FINAL_REPORT.md`。

---

## 24. Definition of Done

只有全部满足才可以宣布完成：

1. 仓库可通过 `swift build`（SPM）直接构建，无需 Xcode 工程。
2. Debug Build 成功。
3. 所有可自动执行的测试成功。
4. App 启动后只有菜单栏入口，设置和登录窗口可以打开。
5. 应用内 X 登录状态可以持久保存；自动测试可用 Mock，真实登录由用户最终执行。
6. 用户可以创建、编辑、暂停和删除监控规则。
7. 频率设置会真实重建 Scheduler。
8. 首次抓取不通知历史推文。
9. 新推文关键词匹配、去重、事件生成完整通过 Mock E2E。
10. macOS 通知代码完整，点击处理代码存在。
11. Telegram Test 和消息发送逻辑通过 Mock 网络测试。
12. X Cookie 不进入业务模型、JSON、日志或 Keychain。
13. Telegram Secret 只在 Keychain。
14. 登录失效、Challenge、限流、网络失败和页面结构变化都有可见状态。
15. 没有任何绕过 CAPTCHA 或访问限制的代码。
16. `scripts/verify.sh` 返回 0。
17. 生成 `dist/XRadar-macOS.zip`，或在无签名环境下明确生成可构建产物及原因。
18. README 包含安装、登录、创建规则、Telegram 配置、隐私和已知限制。
19. `FINAL_REPORT.md` 记录：已完成内容、验证命令、测试结果、遗留限制、用户最终只需执行的动作。
20. 除真实 X 登录、系统权限确认、真实 Telegram Token 和签名证书外，不得把任何实现任务留给用户。

---

## 25. AI 编码规则

1. 先完整阅读本文件，再写代码。
2. 不以“需要确认”为由停止；未规定的小问题选择最简单、可测试、原生的实现。
3. 不扩展 MVP 范围。
4. 每次修改后执行最小相关测试；每个 Phase 后执行完整测试。
5. 不删除、跳过或弱化测试来获得绿色结果。
6. 不使用真实凭据。
7. 不在源代码中硬编码 Token、Chat ID、Cookie 或个人账号。
8. 不使用私有 X API。
9. 不因实时 X 页面无法访问而停止；使用 Fixture 和 Mock 完成全部可验证工作。
10. 对外部不可自动化环节只在最终报告中列出一次，不持续打断用户。
11. 保持 `PROGRESS.md` 简洁，格式：当前阶段、完成项、验证结果、下一步、真实阻塞。
12. 每个阶段创建本地 Git Commit；不自动 Push。
13. 完成后运行一次代码审查：并发、安全、秘密泄漏、错误处理、重复通知、UI 状态。
14. 修复审查发现的问题后再次运行 `verify.sh`。

---

## 26. 官方技术参考

- Apple `MenuBarExtra`：https://developer.apple.com/documentation/swiftui/menubarextra
- Apple `WKWebsiteDataStore`：https://developer.apple.com/documentation/webkit/wkwebsitedatastore
- Apple User Notifications：https://developer.apple.com/documentation/usernotifications
- Apple Keychain Services：https://developer.apple.com/documentation/security/keychain-services
- Apple `SMAppService`：https://developer.apple.com/documentation/servicemanagement/smappservice
- Apple `NSWorkspace.didWakeNotification`：https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification
- X Terms of Service：https://x.com/en/tos

