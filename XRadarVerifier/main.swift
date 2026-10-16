// XRadarVerifier/main.swift
//
// An XCTest-free verification runner so the full test suite can execute in a
// headless environment that has no Xcode.app / XCTest.framework (see README:
// "Test Execution"). It reuses the exact production logic the XCTest suite
// covers, via `@testable import XRadarCore`, and reports pass/fail. Build & run:
//
//   swift build --target XRadarVerifier
//   .build/debug/XRadarVerifier
//
// Exits non-zero if any check fails.
import Foundation
import WebKit
@testable import XRadarCore

// MARK: - Mocks (mirror XRadarTests, kept self-contained for the headless run)

actor MockTimelineProvider: @preconcurrency TimelineProvider {
    var id: TimelineProviderID = .rssHub
    var tweetsToReturn: [Tweet] = MockTimelineProvider.defaultTweets
    var shouldThrow: TimelineError?

    static let defaultTweets: [Tweet] = [
        Tweet(
            id: "1234567890",
            authorHandle: "testuser",
            text: "Just shipped a new feature! 🚀",
            url: URL(string: "https://x.com/testuser/status/1234567890")!,
            publishedAt: Date(),
            kind: .original
        ),
        Tweet(
            id: "1234567891",
            authorHandle: "testuser",
            text: "Check out this image",
            url: URL(string: "https://x.com/testuser/status/1234567891")!,
            publishedAt: Date(),
            kind: .original
        )
    ]

    func setTweets(_ tweets: [Tweet]) async { tweetsToReturn = tweets }
    func setShouldThrow(_ error: TimelineError?) async { shouldThrow = error }

    func fetch(_ request: TimelineRequest) async throws -> TimelineFetchResult {
        if let error = shouldThrow { throw error }
        return TimelineFetchResult(
            tweets: tweetsToReturn,
            providerID: id,
            rawItemCount: tweetsToReturn.count,
            feedState: .healthy
        )
    }
}

@MainActor
final class MockSession: XSessionProtocol {
    var state: XSessionState = .loggedIn(handle: "testuser")

    init(state: XSessionState = .loggedIn(handle: "testuser")) {
        self.state = state
    }

    func presentLogin() async {}
    func validateSession() async -> XSessionState { state }
    func makeAuthenticatedWebView() -> WKWebView { WKWebView() }
    func logout() async throws { state = .loggedOut }
}

actor MockNotificationChannel: @preconcurrency NotificationChannel {
    var id: NotificationChannelID
    var sentEvents: [NotificationEvent] = []
    var shouldFail = false

    init(id: NotificationChannelID) { self.id = id }

    func send(_ event: NotificationEvent) async -> DeliveryResult {
        if shouldFail { return .failure("Mock failure") }
        sentEvents.append(event)
        return .success
    }

    func sendTest() async -> DeliveryResult {
        shouldFail ? .failure("Test failed") : .success
    }
}

actor MockMonitoringPipeline: MonitoringPipelineType {
    var nextSummary: PollRunSummary?
    var callCount = 0
    var activeCount = 0
    var maxConcurrent = 0
    var lastRules: [MonitorRule] = []
    var lastCursors: [String: AccountCursor] = [:]
    var lastSourceSettings: XSourceSettings = .default

    func setNextSummary(_ summary: PollRunSummary?) async { nextSummary = summary }

    func runCheck(
        reason: TriggerReason,
        rules: [MonitorRule],
        accountCursors: [String: AccountCursor],
        sourceSettings: XSourceSettings
    ) async -> PollRunSummary {
        callCount += 1
        activeCount += 1
        maxConcurrent = max(maxConcurrent, activeCount)
        lastRules = rules
        lastCursors = accountCursors
        lastSourceSettings = sourceSettings
        try? await Task.sleep(nanoseconds: 30_000_000)
        activeCount -= 1
        if let summary = nextSummary { return summary }
        return PollRunSummary(
            startTime: Date(), endTime: Date(),
            accountsChecked: rules.count, tweetsFound: 0, eventsGenerated: 0,
            loginRequired: false, actionRequired: nil, rateLimited: false,
            error: nil, isTransientError: false, accountCursors: accountCursors
        )
    }
}

actor MockKeychainStore: KeychainStoreProtocol {
    var token: String? = "fake_bot_token"
    var chatID: String? = "fake_chat_id"

    func loadTelegramBotToken() async throws -> String {
        guard let t = token else { throw KeychainError.itemNotFound }
        return t
    }
    func loadTelegramChatID() async throws -> String {
        guard let c = chatID else { throw KeychainError.itemNotFound }
        return c
    }
    func saveTelegramBotToken(_ token: String) async throws { self.token = token }
    func saveTelegramChatID(_ chatID: String) async throws { self.chatID = chatID }
    func deleteTelegramCredentials() async throws { token = nil; chatID = nil }
    func setToken(_ value: String?) async { token = value }
    func setChatID(_ value: String?) async { chatID = value }
}

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

actor MockDirectFeedProvider: RSSDirectFeedProviding {
    var results: [String: RSSDirectFeedResult] = [:]
    var throwError: SourceError?

    func setResult(for url: String, result: RSSDirectFeedResult) async { results[url] = result }

    func fetch(
        rss url: URL,
        excludedIDs: Set<String>,
        maximumCount: Int,
        etag: String?
    ) async throws -> RSSDirectFeedResult {
        if let throwError { throw throwError }
        if let result = results[url.absoluteString] { return result }
        return RSSDirectFeedResult(tweets: [], rawItemCount: 0, feedState: .healthy, eTag: nil)
    }
}

// MARK: - Helpers

@MainActor
func makeGateway(macos: MockNotificationChannel, telegram: MockNotificationChannel) -> NotificationGateway {
    NotificationGateway(channels: [macos as any NotificationChannel, telegram as any NotificationChannel])
}

@MainActor
func makePipeline(session: MockSession, timeline: MockTimelineProvider, gateway: NotificationGateway) -> MonitoringPipeline {
    let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("XRadarVerifier-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(
        at: testDirectory,
        withIntermediateDirectories: true
    )
    let router = XTimelineRouter(
        webViewProvider: timeline,
        healthTracker: InstanceHealthTracker()
    )
    return MonitoringPipeline(
        router: router,
        ruleEngine: RuleEngine(),
        eventRepository: EventRepository(
            store: JSONFileStore(baseDirectory: testDirectory)
        ),
        notificationGateway: gateway
    )
}

/// 兼容旧 Pipeline 测试的默认信源配置：直接使用 Mock WebView，不访问 RSSHub。
let legacyPipelineSourceSettings = XSourceSettings(
    policy: .xWebOnly,
    rssHubInstances: [],
    webFallbackRiskAcknowledged: false,
    sourceSetupCompleted: true
)

/// 写一份已完成源配置的 AppConfiguration，使 Scheduler 检查可以通过配置门槛。
@MainActor
func saveConfiguredApp(
    _ store: JSONFileStore,
    sourceSetupCompleted: Bool = true,
    extraRules: [MonitorRule] = []
) async {
    var config = AppConfiguration.default
    config.xSourceSettings = legacyPipelineSourceSettings
    config.xSourceSettings.sourceSetupCompleted = sourceSetupCompleted
    config.rules.append(contentsOf: extraRules)
    try? await store.write(config, to: "config.json")
}

func sampleTelegramEvent() -> NotificationEvent {
    NotificationEvent(
        id: "1", tweetID: "1", authorHandle: "alice",
        title: "@alice", body: "Heads up: feature shipped",
        tweetURL: URL(string: "https://x.com/alice/status/1")!,
        matchedRuleIDs: [], matchedKeywords: ["feature"]
    )
}

// MARK: - Checks

@MainActor
func checkAccountURLParsing() -> String? {
    let cases: [(input: String, expected: String)] = [
        ("https://x.com/TestUser", "testuser"),
        ("https://twitter.com/RealDonald", "realdonald"),
        ("@natfriedman", "natfriedman"),
        ("NatFriedman", "natfriedman"),
        ("https://x.com/home", "__throw__"),
        ("not a handle!!!", "__throw__"),
        ("https://example.com/foo", "__throw__")
    ]
    for (input, expected) in cases {
        do {
            let parsed = try XHandleParser.parse(input)
            if expected == "__throw__" { return "expected throw for \(input) but got '\(parsed)'" }
            if parsed != expected { return "parse('\(input)') = '\(parsed)', expected '\(expected)'" }
        } catch {
            if expected != "__throw__" { return "parse('\(input)') threw unexpectedly: \(error)" }
        }
    }
    return nil
}

// MARK: - UI 支撑逻辑（记录归属 / 展示名 / 规则完备性）

func checkRecordRuleMatching() -> String? {
    let feedRule = MonitorRule(name: "GitHub Blog", accountHandle: "github.blog", feedURL: "https://github.blog/feed/")
    let xRule = MonitorRule(name: "Elon", accountHandle: "elonmusk")

    // feed 记录：accountHandle 存的是源 URL 原文
    let feedRecord = FetchRecord(accountHandle: "https://github.blog/feed/", outcome: .matched, message: "x")
    guard feedRecord.belongsTo(rule: feedRule) else { return "feed 记录应归属其 URL 规则" }
    if feedRecord.belongsTo(rule: xRule) { return "feed 记录不应归属 X 规则" }

    // 大小写不敏感（URL scheme/host 大小写差异）
    let mixedRecord = FetchRecord(accountHandle: "HTTPS://GitHub.Blog/feed/", outcome: .noNewTweets, message: "x")
    guard mixedRecord.belongsTo(rule: feedRule) else { return "归属匹配应大小写不敏感" }

    // X 记录按 handle 匹配；显示名不同的 feed 规则不得误收
    let xRecord = FetchRecord(accountHandle: "ElonMusk", outcome: .notMatched, message: "x")
    guard xRecord.belongsTo(rule: xRule) else { return "X 记录应按 handle 大小写不敏感匹配" }
    if xRecord.belongsTo(rule: feedRule) { return "X 记录不应归属 feed 规则" }

    // 显示名：URL 形态 host 化，普通 handle 原样
    if feedRecord.accountDisplayName != "github.blog" {
        return "feed 记录展示名应为 host，实际 \(feedRecord.accountDisplayName)"
    }
    if FetchRecordDisplay.name(for: "https://news.example/items/") != "news.example" {
        return "静态展示名 helper 对 URL 应返回 host"
    }
    if xRecord.accountDisplayName != "ElonMusk" {
        return "X handle 展示名应原样保留"
    }
    return nil
}

@MainActor
func checkEventRetentionPolicy() async -> String? {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("xradar-verify-\(UUID().uuidString)", isDirectory: true)
    let store = JSONFileStore(baseDirectory: tempDir)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    func makeEvent(_ id: String, createdAt: Date) -> NotificationEvent {
        NotificationEvent(
            id: id,
            tweetID: "t-\(id)",
            authorHandle: "someone",
            title: "@someone",
            body: "body \(id)",
            tweetURL: URL(string: "https://x.com/someone/status/1\(id)")!,
            matchedRuleIDs: [],
            matchedKeywords: ["kw"],
            createdAt: createdAt
        )
    }

    // 策略：保留 7 天、上限 3 条。
    let repo = EventRepository(store: store, maxEvents: 3, retentionDays: 7)
    repo.updatePolicy(maxEvents: 3, retentionDays: 7)

    let now = Date()
    let old = now.addingTimeInterval(-10 * 24 * 60 * 60)
    // e1/e2 超龄（应被清），e3/e4/e5 新鲜且恰好等于上限（全部保留）。
    await repo.appendEvents([
        makeEvent("1", createdAt: old),
        makeEvent("2", createdAt: old.addingTimeInterval(-60)),
        makeEvent("3", createdAt: now.addingTimeInterval(-300)),
        makeEvent("4", createdAt: now.addingTimeInterval(-200)),
        makeEvent("5", createdAt: now.addingTimeInterval(-100))
    ])

    let events = await repo.loadEvents()
    guard events.count == 3 else { return "应只剩 3 条新鲜事件，实际 \(events.count)：\(events.map(\.id))" }
    guard Set(events.map(\.id)) == Set(["3", "4", "5"]) else {
        return "超龄事件应被清理、新鲜事件保留，实际 \(events.map(\.id))"
    }

    // 追加第 4 条触发截断：最旧的 e3 应被挤出。
    await repo.appendEvents([makeEvent("6", createdAt: now)])
    let capped = await repo.loadEvents()
    guard Set(capped.map(\.id)) == Set(["4", "5", "6"]) else {
        return "超上限后应挤出最旧事件，实际 \(capped.map(\.id))"
    }

    // updatePolicy 运行时收紧：改为只留 1 条后，再追加立即生效。
    repo.updatePolicy(maxEvents: 1, retentionDays: 7)
    await repo.appendEvents([makeEvent("7", createdAt: now)])
    let after = await repo.loadEvents()
    guard after.count == 1, after.first?.id == "7" else {
        return "收紧到 1 条后应只剩最新事件，实际 \(after.map(\.id))"
    }
    return nil
}

@MainActor
func checkMonitorRuleReadiness() -> String? {
    // X 规则：handle 必填；关键词模式必须至少一个正向关键词。
    if MonitorRule(name: "x", accountHandle: "").isConfigured {
        return "X 规则 handle 为空不应通过"
    }
    if MonitorRule(name: "x", accountHandle: "elonmusk").isConfigured {
        return "关键词模式缺少正向关键词不应通过校验"
    }
    if !MonitorRule(name: "x", accountHandle: "  elonmusk  ", includeKeywords: ["ai"]).isConfigured {
        return "带空白 handle 与关键词的 X 规则应通过"
    }

    // allNewTweets 模式不要求关键词
    if !MonitorRule(name: "x", accountHandle: "elonmusk", triggerMode: .allNewTweets).isConfigured {
        return "全量模式无关键词也应通过"
    }

    // feed 规则 URL 校验：非法 / 相对 / 非 http(s) / X 域名一律拒绝。
    let badURLs = ["notaurl", "/relative/path", "ftp://example.com/rss",
                   "https://x.com/user/feed", "http://twitter.com/feed"]
    for bad in badURLs {
        if MonitorRule(name: "f", accountHandle: "site", feedURL: bad, includeKeywords: ["ai"]).isConfigured {
            return "feed 地址 '\(bad)' 不应通过校验"
        }
    }
    let goodURLs = ["https://github.blog/feed/", "http://localhost:1200/feed.xml"]
    for good in goodURLs {
        if !MonitorRule(name: "f", accountHandle: "site", feedURL: good, includeKeywords: ["ai"]).isConfigured {
            return "feed 地址 '\(good)' 应通过校验"
        }
    }
    // feed + 关键词模式空关键词 → 禁止（否则规则静默失效）
    if MonitorRule(name: "f", accountHandle: "site", feedURL: "https://github.blog/feed/").isConfigured {
        return "feed 关键词模式空关键词不应通过"
    }
    // feed + 全量模式 → 通过
    if !MonitorRule(name: "f", accountHandle: "site", feedURL: "https://github.blog/feed/", triggerMode: .allNewTweets).isConfigured {
        return "feed 全量模式应通过"
    }
    return nil
}

@MainActor
func checkKeywordWordBoundary() -> String? {
    let matcher = KeywordMatcher()

    func makeTweet(_ text: String) -> Tweet {
        Tweet(
            id: UUID().uuidString,
            authorHandle: "someone",
            text: text,
            url: URL(string: "https://example.com/x")!,
            publishedAt: Date(),
            kind: .original,
            isPinned: false
        )
    }

    func feedRule(include: [String], exclude: [String] = []) -> MonitorRule {
        MonitorRule(
            name: "boundary",
            accountHandle: "site",
            feedURL: "https://example.com/feed",
            includeKeywords: include,
            excludeKeywords: exclude
        )
    }

    // 左词边界：英文短词不再误中包含它的单词。
    if matcher.evaluate(tweet: makeTweet("线下活动｜Echoes Remain：唱片展"), rule: feedRule(include: ["AI"])) != nil {
        return "关键词 'AI' 不应子串命中 'Remain'"
    }
    if matcher.evaluate(tweet: makeTweet("email 泛滥的一天"), rule: feedRule(include: ["mail"])) != nil {
        return "关键词 'mail' 不应命中 'email'（起始字符是字母）"
    }

    // 正常命中不受影响；前缀延展保留（Swift → SwiftUI）。
    guard let hit = matcher.evaluate(tweet: makeTweet("DeepSeek AI 模型发布"), rule: feedRule(include: ["AI"])) else {
        return "'AI' 应正常命中"
    }
    if hit.matchedKeywords != ["AI"] { return "命中关键词应为 AI" }
    if matcher.evaluate(tweet: makeTweet("SwiftUI 教程合集"), rule: feedRule(include: ["Swift"])) == nil {
        return "前缀延展应保留：'Swift' 命中 'SwiftUI'"
    }

    // 中文/混合关键词保持子串语义。
    if matcher.evaluate(tweet: makeTweet("苹果发布会预告"), rule: feedRule(include: ["苹果"])) == nil {
        return "中文关键词应保持子串语义"
    }
    if matcher.evaluate(tweet: makeTweet("iOS版已发布"), rule: feedRule(include: ["iOS"])) == nil {
        return "紧邻 CJK 的英文关键词应可命中"
    }

    // 排除关键词同样使用左词边界。
    if matcher.evaluate(tweet: makeTweet("Remain 展览模型"), rule: feedRule(include: ["模型"], exclude: ["ai"])) == nil {
        return "排除词 'ai' 不应因子串误杀 'Remain'"
    }
    if matcher.evaluate(tweet: makeTweet("ai 模型速览"), rule: feedRule(include: ["模型"], exclude: ["ai"])) != nil {
        return "排除词 'ai' 应正常排除"
    }
    return nil
}

@MainActor
func checkGatewayDeliveryPolicy() async -> String? {
    let macos = MockNotificationChannel(id: .macOS)
    let telegram = MockNotificationChannel(id: .telegram)
    let gateway = NotificationGateway(channels: [macos, telegram])
    let event = sampleTelegramEvent()

    // 默认（未 configure）：不应全通道常开之外有意外行为——先关 Telegram。
    await gateway.configure(macOSEnabled: true, macOSSoundEnabled: false, telegramEnabled: false)
    let onlyMac = await gateway.deliver(event: event, through: [.macOS, .telegram])
    guard Set(onlyMac.keys) == Set([NotificationChannelID.macOS]) else {
        return "telegramEnabled=false 时应只投递 macOS，实际 \(onlyMac.keys)"
    }
    let tgCount1 = await telegram.sentEvents.count
    guard tgCount1 == 0 else { return "Telegram 关闭时不应收到事件，实际 \(tgCount1) 条" }

    // 全部关闭：无任何投递。
    await gateway.configure(macOSEnabled: false, macOSSoundEnabled: false, telegramEnabled: false)
    let none = await gateway.deliver(event: event, through: [.macOS, .telegram])
    guard none.isEmpty else { return "全部关闭时应无投递，实际 \(none.keys)" }

    // 重新打开：两个通道都恢复。
    await gateway.configure(macOSEnabled: true, macOSSoundEnabled: false, telegramEnabled: true)
    let both = await gateway.deliver(event: event, through: [.macOS, .telegram])
    guard Set(both.keys) == Set([.macOS, .telegram]) else { return "重新开启后应双通道投递，实际 \(both.keys)" }
    let tgCount2 = await telegram.sentEvents.count
    guard tgCount2 == 1 else { return "重新开启后 Telegram 应收到 1 条，实际 \(tgCount2)" }
    return nil
}

@MainActor
func checkKeywordMatching() async -> String? {
    let session = MockSession()
    let timeline = MockTimelineProvider()
    let macos = MockNotificationChannel(id: .macOS)
    let telegram = MockNotificationChannel(id: .telegram)
    let gateway = makeGateway(macos: macos, telegram: telegram)
    let pipeline = makePipeline(session: session, timeline: timeline, gateway: gateway)

    let rule = MonitorRule(
        name: "Keyword Test", accountHandle: "testuser",
        triggerMode: .keywords,
        includeKeywords: ["feature", "shipped"],
        keywordMatchMode: .any,
        notificationChannels: [.macOS]
    )
    let cursor = AccountCursor(
        seenTweetIDs: ["old1"], initialized: true,
        lastCheckedAt: Date(), lastSuccessfulFetchAt: nil, lastErrorCode: nil
    )
    let summary = await pipeline.runCheck(
        reason: .scheduled, rules: [rule], accountCursors: ["testuser": cursor],
        sourceSettings: legacyPipelineSourceSettings
    )
    let events = await macos.sentEvents
    guard !events.isEmpty else { return "no notification on keyword match" }
    guard events.first?.body.contains("feature") ?? false else {
        return "event body missing keyword: \(events.first?.body ?? "")"
    }
    if summary.eventsGenerated == 0 { return "summary.eventsGenerated was 0" }
    return nil
}

@MainActor
func checkFirstBaseline() async -> String? {
    let session = MockSession()
    let timeline = MockTimelineProvider()
    let macos = MockNotificationChannel(id: .macOS)
    let telegram = MockNotificationChannel(id: .telegram)
    let gateway = makeGateway(macos: macos, telegram: telegram)
    let pipeline = makePipeline(session: session, timeline: timeline, gateway: gateway)

    let rule = MonitorRule(
        name: "Baseline", accountHandle: "testuser",
        triggerMode: .allNewTweets, notificationChannels: [.macOS]
    )
    let summary = await pipeline.runCheck(
        reason: .scheduled, rules: [rule], accountCursors: ["testuser": .empty],
        sourceSettings: legacyPipelineSourceSettings
    )
    let events = await macos.sentEvents
    if !events.isEmpty { return "first baseline must NOT notify, got \(events.count)" }
    if summary.eventsGenerated != 0 { return "baseline eventsGenerated != 0" }
    return nil
}

@MainActor
func checkDedupAcrossRestart() async -> String? {
    let session = MockSession()
    let timeline = MockTimelineProvider()
    let macos = MockNotificationChannel(id: .macOS)
    let telegram = MockNotificationChannel(id: .telegram)
    let gateway = makeGateway(macos: macos, telegram: telegram)
    let pipeline = makePipeline(session: session, timeline: timeline, gateway: gateway)

    let rule = MonitorRule(
        name: "Dedup", accountHandle: "testuser",
        triggerMode: .keywords, includeKeywords: ["feature"],
        keywordMatchMode: .any, notificationChannels: [.macOS]
    )

    // Run 1: baseline.
    let s1 = await pipeline.runCheck(
        reason: .scheduled, rules: [rule], accountCursors: ["testuser": .empty],
        sourceSettings: legacyPipelineSourceSettings
    )
    if s1.eventsGenerated != 0 { return "baseline should not notify" }
    let c1 = s1.accountCursors["testuser"]!
    if !c1.initialized { return "cursor not initialized after baseline" }
    if Set(c1.seenTweetIDs) != Set(["1234567890", "1234567891"]) {
        return "baseline seen IDs wrong: \(c1.seenTweetIDs)"
    }

    // Run 2: simulated restart, same tweets -> no re-notify.
    let s2 = await pipeline.runCheck(
        reason: .scheduled, rules: [rule], accountCursors: ["testuser": c1],
        sourceSettings: legacyPipelineSourceSettings
    )
    if s2.eventsGenerated != 0 { return "seen tweets re-notified after restart" }

    // Run 3: brand-new matching tweet.
    await timeline.setTweets(
        MockTimelineProvider.defaultTweets + [
            Tweet(id: "999", authorHandle: "testuser", text: "feature launch now",
                  url: URL(string: "https://x.com/testuser/status/999")!,
                  publishedAt: Date().addingTimeInterval(60), kind: .original)
        ]
    )
    let s3 = await pipeline.runCheck(
        reason: .scheduled, rules: [rule], accountCursors: ["testuser": c1],
        sourceSettings: legacyPipelineSourceSettings
    )
    if s3.eventsGenerated != 1 { return "new tweet should notify exactly once, got \(s3.eventsGenerated)" }
    return nil
}

@MainActor
func checkSchedulerReentrancy() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let pipeline = MockMonitoringPipeline()
    let repo = StateRepository(store: JSONFileStore(baseDirectory: tempDir))
    let configRepo = ConfigurationRepository(store: JSONFileStore(baseDirectory: tempDir))
    let store = JSONFileStore(baseDirectory: tempDir)
    await saveConfiguredApp(store)
    let scheduler = PollScheduler(pipeline: pipeline, stateRepository: repo, configRepository: configRepo)

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<12 {
            group.addTask { await scheduler.runCheck(reason: .manual) }
        }
    }
    let maxConcurrent = await pipeline.maxConcurrent
    let callCount = await pipeline.callCount
    if maxConcurrent > 1 { return "concurrent runCheck overlapped (maxConcurrent=\(maxConcurrent))" }
    if callCount != 1 { return "expected only 1 in-flight pass, got \(callCount)" }

    for _ in 0..<5 { await scheduler.runCheck(reason: .manual) }
    let callCount2 = await pipeline.callCount
    if callCount2 != 6 { return "expected 6 total passes, got \(callCount2)" }
    if await pipeline.maxConcurrent > 1 { return "sequential passes overlapped" }
    return nil
}

@MainActor
func checkSchedulerPauseGatesManualAndWake() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let pipeline = MockMonitoringPipeline()
    let store = JSONFileStore(baseDirectory: tempDir)
    await saveConfiguredApp(store)
    let scheduler = PollScheduler(
        pipeline: pipeline,
        stateRepository: StateRepository(store: store),
        configRepository: ConfigurationRepository(store: store)
    )

    // 暂停（stop）后：手动与唤醒触发都不得执行检查。
    await scheduler.stop()
    await scheduler.triggerNow(reason: .manual)
    await scheduler.triggerNow(reason: .wake)
    try? await Task.sleep(for: .milliseconds(120))
    let pausedCount = await pipeline.callCount
    guard pausedCount == 0 else { return "暂停后 triggerNow 不应执行检查，实际 \(pausedCount) 次" }

    // 恢复后：手动触发应正常执行一次。
    await scheduler.start()
    await scheduler.triggerNow(reason: .manual)
    for _ in 0..<50 {
        if await pipeline.callCount > 0 { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    let resumedCount = await pipeline.callCount
    guard resumedCount >= 1 else { return "恢复后手动检查应执行，实际 0 次" }
    return nil
}

@MainActor
func checkStatusClassification() -> String? {
    func makeSummary(
        error: String?,
        transient: Bool,
        loginRequired: Bool = false,
        configRequired: Bool = false
    ) -> RunSummary {
        RunSummary(
            accountsChecked: 1, tweetsFound: 0, eventsGenerated: 0,
            loginRequired: loginRequired, actionRequired: nil, rateLimited: false,
            error: error, isTransientError: transient,
            configurationRequired: configRequired, finishedAt: Date()
        )
    }

    var state = RuntimeState.default

    // 结构化标志：瞬态错误 → idle（不再做错误文案匹配）。
    state.lastRunSummary = makeSummary(error: "请求超时", transient: true)
    guard case .idle = state.status else { return "瞬态错误应显示 idle，实际 \(state.status)" }

    state.lastRunSummary = makeSummary(error: "配置损坏", transient: false)
    guard case .degraded(let message) = state.status, message == "配置损坏" else {
        return "非瞬态错误应显示 degraded"
    }

    // 优先级：configurationRequired > loginRequired。
    state.lastRunSummary = makeSummary(error: nil, transient: false, loginRequired: true)
    guard case .loginRequired = state.status else { return "loginRequired 应正确显示" }
    state.lastRunSummary = makeSummary(error: "任意", transient: true, configRequired: true)
    guard case .configurationRequired = state.status else {
        return "configurationRequired 应优先于其他状态"
    }
    return nil
}

@MainActor
func checkStatusNavigationHint() -> String? {
    let now = Date()
    let cases: [(status: AppRunStatus, tab: Int?)] = [
        (.configurationRequired, 0),
        (.loginRequired, 1),
        (.actionRequired("验证"), 1),
        (.backingOff(until: now, reason: "限流"), 3),
        (.degraded("异常"), 3),
        (.idle(nextRunAt: nil), nil),
        (.running(startedAt: now), nil),
        (.paused, nil)
    ]
    for (status, expected) in cases {
        guard status.suggestedSettingsTabIndex == expected else {
            return "\(status) 的引导 tab 应为 \(String(describing: expected))"
        }
    }
    // 手动检查拦截原因只在注定失败的状态出现。
    if AppRunStatus.configurationRequired.manualCheckBlockedReason == nil {
        return "configurationRequired 应给出拦截原因"
    }
    if AppRunStatus.loginRequired.manualCheckBlockedReason == nil {
        return "loginRequired 应给出拦截原因"
    }
    if AppRunStatus.idle(nextRunAt: nil).manualCheckBlockedReason != nil {
        return "idle 不应有拦截原因"
    }
    return nil
}

@MainActor
func checkFailureRecordProviderHint() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = JSONFileStore(baseDirectory: tempDir)
    await saveConfiguredApp(store)
    let history = FetchHistoryRepository(store: store, maxRecords: 20)

    // RSSHub 实例返回 503：走真实 HTTP 层的失败路径。
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    let router = XTimelineRouter(
        webViewProvider: MockTimelineProvider(),
        healthTracker: InstanceHealthTracker(),
        rssHubClientFactory: { _ in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: ["mock.rsshub"])
        }
    )
    let pipeline = MonitoringPipeline(
        router: router,
        ruleEngine: RuleEngine(),
        eventRepository: EventRepository(store: store),
        notificationGateway: makeGateway(macos: MockNotificationChannel(id: .macOS),
                                         telegram: MockNotificationChannel(id: .telegram)),
        fetchHistoryRepository: history
    )

    let settings = XSourceSettings(
        policy: .rssHubOnly,
        rssHubInstances: ["https://mock.rsshub"],
        webFallbackRiskAcknowledged: false,
        sourceSetupCompleted: true
    )
    let rule = MonitorRule(name: "r", accountHandle: "someone")
    let summary = await pipeline.runCheck(
        reason: .manual,
        rules: [rule],
        accountCursors: [:],
        sourceSettings: settings
    )
    guard summary.error != nil else { return "503 应产生错误" }

    let records = await history.loadRecords()
    guard let failure = records.first(where: { $0.outcome == .fetchFailed }) else {
        return "应产生抓取失败记录，实际 \(records.map(\.outcome))"
    }
    guard failure.providerID == .rssHub else {
        return "失败记录应标注来源 Provider=rssHub，实际 \(String(describing: failure.providerID))"
    }
    return nil
}

@MainActor
func checkCooldownNoiseSuppression() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = JSONFileStore(baseDirectory: tempDir)
    await saveConfiguredApp(store)
    let history = FetchHistoryRepository(store: store, maxRecords: 50)
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    func makePipeline() -> MonitoringPipeline {
        MonitoringPipeline(
            router: XTimelineRouter(
                webViewProvider: MockTimelineProvider(),
                healthTracker: InstanceHealthTracker(),
                rssHubClientFactory: { _ in
                    let config = URLSessionConfiguration.ephemeral
                    config.protocolClasses = [MockURLProtocol.self]
                    return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: ["mock.rsshub"])
                }
            ),
            ruleEngine: RuleEngine(),
            eventRepository: EventRepository(store: store),
            notificationGateway: makeGateway(macos: MockNotificationChannel(id: .macOS),
                                             telegram: MockNotificationChannel(id: .telegram)),
            fetchHistoryRepository: history
        )
    }
    let settings = XSourceSettings(
        policy: .rssHubOnly,
        rssHubInstances: ["https://mock.rsshub"],
        webFallbackRiskAcknowledged: false,
        sourceSetupCompleted: true
    )
    let rule = MonitorRule(name: "r", accountHandle: "someone")

    // 第一轮：实例 503 → 记一条失败。
    _ = await makePipeline().runCheck(reason: .manual, rules: [rule], accountCursors: [:], sourceSettings: settings)

    // 第二轮（新 pipeline、共享 history）：全部实例已冷却 → 抛 instancesCoolingDown，
    // 且文案与 cursor.lastErrorCode 一致 → 不应再追加失败行。
    // 注意：冷却状态在 healthTracker 内存里，跨 pipeline 需重建冷却；
    // 直接用同一 tracker 实例模拟连续轮次。
    let tracker = InstanceHealthTracker()
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    let pipeline2 = MonitoringPipeline(
        router: XTimelineRouter(
            webViewProvider: MockTimelineProvider(),
            healthTracker: tracker,
            rssHubClientFactory: { _ in
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [MockURLProtocol.self]
                return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: ["mock.rsshub"])
            }
        ),
        ruleEngine: RuleEngine(),
        eventRepository: EventRepository(store: store),
        notificationGateway: makeGateway(macos: MockNotificationChannel(id: .macOS),
                                         telegram: MockNotificationChannel(id: .telegram)),
        fetchHistoryRepository: history
    )
    // 轮 A：真实请求失败，进入冷却并写历史；游标随轮次持久流转（生产中由
    // Scheduler 传入持久化的 runtimeState.accounts）。
    let summaryA = await pipeline2.runCheck(reason: .manual, rules: [rule], accountCursors: [:], sourceSettings: settings)
    let afterA = await history.loadRecords()
    let failuresA = afterA.filter { $0.outcome == .fetchFailed }.count

    // 轮 B：全冷却，错误文案与上轮一致 → 历史不应增长。
    _ = await pipeline2.runCheck(reason: .manual, rules: [rule], accountCursors: summaryA.accountCursors, sourceSettings: settings)
    let afterB = await history.loadRecords()
    let failuresB = afterB.filter { $0.outcome == .fetchFailed }.count

    // 轮 C：冷却到期后根因变化（503→超时）→ 应重新记录一条新失败。
    MockURLProtocol.requestHandler = { _ in throw URLError(.timedOut) }
    await tracker.reset()
    _ = await pipeline2.runCheck(reason: .manual, rules: [rule], accountCursors: summaryA.accountCursors, sourceSettings: settings)
    let afterC = await history.loadRecords()
    let failuresC = afterC.filter { $0.outcome == .fetchFailed }.count

    guard failuresA >= 1 else { return "首轮应至少记录一次失败" }
    guard failuresB == failuresA else {
        return "冷却重复错误不应刷屏（\(failuresA) → \(failuresB)）"
    }
    guard failuresC == failuresB + 1 else {
        return "冷却到期且根因变化后应记录新失败（\(failuresB) → \(failuresC)）"
    }
    return nil
}

@MainActor
func checkStatePersistence() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = JSONFileStore(baseDirectory: tempDir)

    var state = RuntimeState.default
    state.isPaused = true
    state.accounts = [
        "alice": AccountCursor(
            seenTweetIDs: ["1", "2", "3"], initialized: true,
            lastCheckedAt: Date(), lastSuccessfulFetchAt: Date(), lastErrorCode: nil
        )
    ]
    try? await store.write(state, to: "state.json")
    let read = await store.read(RuntimeState.self, from: "state.json")
    guard let read else { return "round-trip read returned nil" }
    if !read.isPaused { return "isPaused not persisted" }
    if read.accounts["alice"]?.seenTweetIDs != ["1", "2", "3"] { return "accounts not persisted" }

    // Corrupt main, backup should recover.
    try? await store.write(RuntimeState.default, to: "state.json")
    let corruptURL = tempDir.appendingPathComponent("state.json")
    try? "this is not json {{{".write(to: corruptURL, atomically: true, encoding: .utf8)
    let recovered = await store.read(RuntimeState.self, from: "state.json")
    guard recovered != nil else { return "did not recover from .bak backup" }

    // Corrupt with no backup -> nil.
    let corruptURL2 = tempDir.appendingPathComponent("state2.json")
    try? "garbage".write(to: corruptURL2, atomically: true, encoding: .utf8)
    let nilResult = await store.read(RuntimeState.self, from: "state2.json")
    if nilResult != nil { return "expected nil with no valid file/backup" }

    // Scheduler persists cursors across runs.
    let pipeline = MockMonitoringPipeline()
    let repo = StateRepository(store: store)
    let configRepo = ConfigurationRepository(store: store)
    await saveConfiguredApp(store)
    let scheduler = PollScheduler(pipeline: pipeline, stateRepository: repo, configRepository: configRepo)
    await pipeline.setNextSummary(
        PollRunSummary(
            startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 2,
            eventsGenerated: 0, loginRequired: false, actionRequired: nil, rateLimited: false,
            error: nil, isTransientError: false,
            accountCursors: [
                "bob": AccountCursor(
                    seenTweetIDs: ["a", "b"], initialized: true,
                    lastCheckedAt: Date(), lastSuccessfulFetchAt: Date(), lastErrorCode: nil
                )
            ]
        )
    )
    await scheduler.runCheck(reason: .manual)
    let persisted = await repo.load()
    if persisted.accounts["bob"]?.seenTweetIDs != ["a", "b"] { return "scheduler did not persist bob cursor" }
    await scheduler.runCheck(reason: .manual)
    let handedBack = await pipeline.lastCursors
    if handedBack["bob"]?.seenTweetIDs != ["a", "b"] { return "persisted cursor not handed back to pipeline" }

    return nil
}

@MainActor
func checkTelegramErrors() async -> String? {
    let keychain = MockKeychainStore()

    func session(for handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    // Success
    do {
        let s = session { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let r = await TelegramNotifier(keychainStore: keychain, session: s).send(sampleTelegramEvent())
        if !r.success { return "success case failed: \(r.errorMessage ?? "")" }
    }
    // 400
    do {
        let s = session { req in
            (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
        }
        let r = await TelegramNotifier(keychainStore: keychain, session: s).send(sampleTelegramEvent())
        if r.success { return "400 should fail" }
        if r.errorMessage != "Configuration error (HTTP 400)" { return "400 message wrong: \(r.errorMessage ?? "")" }
    }
    // 429
    do {
        let s = session { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        let r = await TelegramNotifier(keychainStore: keychain, session: s).send(sampleTelegramEvent())
        if r.success { return "429 should fail" }
        if r.errorMessage != "Rate limited" { return "429 message wrong: \(r.errorMessage ?? "")" }
    }
    // 500 then 200 -> retry succeeds
    do {
        var calls = 0
        let s = session { req in
            calls += 1
            let code = calls == 1 ? 500 : 200
            return (HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data())
        }
        let r = await TelegramNotifier(keychainStore: keychain, session: s).send(sampleTelegramEvent())
        if !r.success { return "500 retry should succeed: \(r.errorMessage ?? "")" }
        if calls != 2 { return "expected 2 calls after retry, got \(calls)" }
    }
    // Network error
    do {
        let s = session { _ in throw URLError(.notConnectedToInternet) }
        let r = await TelegramNotifier(keychainStore: keychain, session: s).send(sampleTelegramEvent())
        if r.success { return "network error should fail" }
        if !(r.errorMessage?.hasPrefix("Network error") ?? false) { return "network error msg wrong: \(r.errorMessage ?? "")" }
    }
    // Missing credentials
    do {
        await keychain.setToken(nil)
        let s = session { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let r = await TelegramNotifier(keychainStore: keychain, session: s).send(sampleTelegramEvent())
        if r.success { return "missing credentials should fail" }
        if r.errorMessage != "Telegram credentials not configured" { return "missing creds msg wrong: \(r.errorMessage ?? "")" }
    }
    return nil
}

func checkLoginStateMachine() -> String? {
    if !XSessionState.loggedIn(handle: "x").isLoggedIn { return "loggedIn.isLoggedIn false" }
    if !XSessionState.probablyLoggedIn.isLoggedIn { return "probablyLoggedIn.isLoggedIn false" }
    if XSessionState.loggedOut.isLoggedIn { return "loggedOut.isLoggedIn true" }
    if !XSessionState.loggedIn(handle: "x").isPossiblyLoggedIn { return "loggedIn.isPossiblyLoggedIn false" }
    if XSessionState.loggedOut.isPossiblyLoggedIn { return "loggedOut.isPossiblyLoggedIn true" }
    if XSessionState.loggedOut.notLoggedInReason != "X 登录已失效，请重新登录" {
        return "loggedOut reason wrong"
    }
    if XSessionState.actionRequired(message: "验证").actionRequiredMessage != "验证" {
        return "actionRequiredMessage wrong"
    }
    if XSessionState.actionRequired(message: "验证").notLoggedInReason != "需要处理: 验证" {
        return "actionRequired notLoggedInReason wrong"
    }
    if XSessionState.failed(message: "boom").notLoggedInReason != "登录验证失败: boom" {
        return "failed notLoggedInReason wrong"
    }
    if XSessionState.validating.notLoggedInReason != "登录状态未知" {
        return "validating notLoggedInReason wrong"
    }

    var s = RuntimeState.default
    if s.status != .idle(nextRunAt: nil) { return "default status not idle" }
    s.isPaused = true
    if s.status != .paused { return "paused status wrong" }
    s.isPaused = false

    s.lastRunSummary = RunSummary(
        accountsChecked: 0, tweetsFound: 0, eventsGenerated: 0,
        loginRequired: true, actionRequired: nil, rateLimited: false,
        error: nil, isTransientError: false, finishedAt: Date()
    )
    if s.status != .loginRequired { return "loginRequired status wrong" }

    s.lastRunSummary = RunSummary(
        accountsChecked: 0, tweetsFound: 0, eventsGenerated: 0,
        loginRequired: false, actionRequired: "人机验证", rateLimited: false,
        error: nil, isTransientError: false, finishedAt: Date()
    )
    if s.status != .actionRequired("人机验证") { return "actionRequired status wrong" }

    s.lastRunSummary = RunSummary(
        accountsChecked: 0, tweetsFound: 0, eventsGenerated: 0,
        loginRequired: false, actionRequired: nil, rateLimited: false,
        error: "页面解析失败", isTransientError: false, finishedAt: Date()
    )
    if s.status != .degraded("页面解析失败") { return "degraded status wrong" }

    s.lastRunSummary = nil
    s.backoffUntil = Date().addingTimeInterval(30)
    if case .backingOff = s.status { /* ok */ } else { return "expected backingOff status" }
    return nil
}

@MainActor
func checkMockFullChain() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    func freshScheduler() async -> (PollScheduler, MockMonitoringPipeline, StateRepository) {
        let pipeline = MockMonitoringPipeline()
        let store = JSONFileStore(baseDirectory: tempDir)
        await saveConfiguredApp(store)
        let repo = StateRepository(store: store)
        let configRepo = ConfigurationRepository(store: store)
        let scheduler = PollScheduler(pipeline: pipeline, stateRepository: repo, configRepository: configRepo)
        return (scheduler, pipeline, repo)
    }

    // loginRequired -> status
    do {
        let (scheduler, pipeline, repo) = await freshScheduler()
        await pipeline.setNextSummary(
            PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 0,
                           eventsGenerated: 0, loginRequired: true, actionRequired: nil, rateLimited: false,
                           error: "X 登录已失效，请重新登录", isTransientError: false, accountCursors: [:])
        )
        await scheduler.runCheck(reason: .manual)
        let st = await repo.load()
        if !(st.lastRunSummary?.loginRequired ?? false) { return "loginRequired not persisted" }
        if st.status != .loginRequired { return "status not loginRequired" }
    }
    // rateLimited -> backoff + status
    do {
        let (scheduler, pipeline, repo) = await freshScheduler()
        await pipeline.setNextSummary(
            PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 0,
                           eventsGenerated: 0, loginRequired: false, actionRequired: nil, rateLimited: true,
                           error: nil, isTransientError: false, accountCursors: [:])
        )
        await scheduler.runCheck(reason: .manual)
        let st = await repo.load()
        if !(st.lastRunSummary?.rateLimited ?? false) { return "rateLimited not persisted" }
        if st.backoffUntil == nil { return "backoffUntil not set on rate limit" }
    }
    // actionRequired -> status
    do {
        let (scheduler, pipeline, repo) = await freshScheduler()
        await pipeline.setNextSummary(
            PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 0,
                           eventsGenerated: 0, loginRequired: false, actionRequired: "请完成人机验证", rateLimited: false,
                           error: nil, isTransientError: false, accountCursors: [:])
        )
        await scheduler.runCheck(reason: .manual)
        let st = await repo.load()
        if st.status != .actionRequired("请完成人机验证") { return "status not actionRequired" }
    }
    // transient error -> status should enter a quiet backoff, not degraded
    do {
        let (scheduler, pipeline, repo) = await freshScheduler()
        await pipeline.setNextSummary(
            PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 0,
                           eventsGenerated: 0, loginRequired: false, actionRequired: nil, rateLimited: false,
                           error: "page structure changed", isTransientError: true, accountCursors: [:])
        )
        await scheduler.runCheck(reason: .manual)
        let st = await repo.load()
        if st.lastRunSummary?.isTransientError != true { return "isTransientError not persisted" }
        if case .backingOff = st.status { /* expected */ }
        else { return "transient error should enter backoff, got \(st.status)" }
    }
    // non-transient error -> status should be degraded
    do {
        let (scheduler, pipeline, repo) = await freshScheduler()
        await pipeline.setNextSummary(
            PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 0,
                           eventsGenerated: 0, loginRequired: false, actionRequired: nil, rateLimited: false,
                           error: "permanent failure", isTransientError: false, accountCursors: [:])
        )
        await scheduler.runCheck(reason: .manual)
        let st = await repo.load()
        if case .degraded(let msg) = st.status {
            if msg != "permanent failure" { return "degraded message mismatch" }
        } else {
            return "non-transient error should show degraded, got \(st.status)"
        }
    }
    return nil
}

// MARK: - Runner

func checkKeywordExcludeAndAll() -> String? {
    let matcher = KeywordMatcher()
    let tweet = Tweet(
        id: "1", authorHandle: "alice",
        text: "Breaking news: Apple ships new feature",
        url: URL(string: "https://x.com/alice/status/1")!, kind: .original
    )

    // Exclude keyword blocks match
    let excludeRule = MonitorRule(
        name: "Excl", accountHandle: "alice",
        triggerMode: .keywords,
        includeKeywords: ["apple"],
        excludeKeywords: ["breaking"],
        keywordMatchMode: .any
    )
    if matcher.evaluate(tweet: tweet, rule: excludeRule) != nil {
        return "exclude keyword should block match"
    }

    // All mode: both keywords required
    let allRule = MonitorRule(
        name: "All", accountHandle: "alice",
        triggerMode: .keywords,
        includeKeywords: ["apple", "feature"],
        keywordMatchMode: .all
    )
    let allMatch = matcher.evaluate(tweet: tweet, rule: allRule)
    if allMatch == nil { return "all mode should match when both keywords present" }
    if allMatch?.matchedKeywords.count != 2 { return "all mode should report 2 keywords" }

    // All mode: missing one keyword
    let allRule2 = MonitorRule(
        name: "All2", accountHandle: "alice",
        triggerMode: .keywords,
        includeKeywords: ["apple", "missing"],
        keywordMatchMode: .all
    )
    if matcher.evaluate(tweet: tweet, rule: allRule2) != nil {
        return "all mode should not match when one keyword missing"
    }

    // Only exclude keywords (no include) -> no match
    let onlyExclude = MonitorRule(
        name: "OnlyExcl", accountHandle: "alice",
        triggerMode: .keywords,
        includeKeywords: [],
        excludeKeywords: ["breaking"],
        keywordMatchMode: .any
    )
    if matcher.evaluate(tweet: tweet, rule: onlyExclude) != nil {
        return "no include keywords should return nil"
    }

    // allNewTweets mode matches regardless of text
    let allTweets = MonitorRule(
        name: "AllTweets", accountHandle: "alice",
        triggerMode: .allNewTweets
    )
    let atMatch = matcher.evaluate(tweet: tweet, rule: allTweets)
    if atMatch == nil { return "allNewTweets should match" }
    if atMatch?.reason != .allNewTweets { return "reason should be allNewTweets" }

    return nil
}

func checkUnicodeNormalization() -> String? {
    let matcher = KeywordMatcher()

    // Fullwidth vs halfwidth
    let fullwidthTweet = Tweet(
        id: "2", authorHandle: "bob",
        text: "Ｈｅｌｌｏ Ｗｏｒｌｄ",
        url: URL(string: "https://x.com/bob/status/2")!, kind: .original
    )
    let rule = MonitorRule(
        name: "FW", accountHandle: "bob",
        triggerMode: .keywords,
        includeKeywords: ["hello"],
        keywordMatchMode: .any
    )
    if matcher.evaluate(tweet: fullwidthTweet, rule: rule) == nil {
        return "fullwidth text should match halfwidth keyword"
    }

    // Diacritic insensitive
    let diacriticTweet = Tweet(
        id: "3", authorHandle: "bob",
        text: "Café résumé naïve",
        url: URL(string: "https://x.com/bob/status/3")!, kind: .original
    )
    let diacriticRule = MonitorRule(
        name: "Diac", accountHandle: "bob",
        triggerMode: .keywords,
        includeKeywords: ["cafe"],
        keywordMatchMode: .any
    )
    if matcher.evaluate(tweet: diacriticTweet, rule: diacriticRule) == nil {
        return "diacritic insensitive match failed"
    }

    // Chinese keyword
    let chineseTweet = Tweet(
        id: "4", authorHandle: "bob",
        text: "今天发布了新功能",
        url: URL(string: "https://x.com/bob/status/4")!, kind: .original
    )
    let chineseRule = MonitorRule(
        name: "CN", accountHandle: "bob",
        triggerMode: .keywords,
        includeKeywords: ["新功能"],
        keywordMatchMode: .any
    )
    if matcher.evaluate(tweet: chineseTweet, rule: chineseRule) == nil {
        return "Chinese keyword match failed"
    }

    // Emoji in tweet text doesn't crash
    let emojiTweet = Tweet(
        id: "5", authorHandle: "bob",
        text: "🚀🔥 Launch day! 🎉",
        url: URL(string: "https://x.com/bob/status/5")!, kind: .original
    )
    let emojiRule = MonitorRule(
        name: "Emoji", accountHandle: "bob",
        triggerMode: .keywords,
        includeKeywords: ["🚀"],
        keywordMatchMode: .any
    )
    if matcher.evaluate(tweet: emojiTweet, rule: emojiRule) == nil {
        return "emoji keyword match failed"
    }

    return nil
}

func checkTweetTypeFiltering() -> String? {
    let matcher = KeywordMatcher()

    let replyTweet = Tweet(
        id: "10", authorHandle: "carol",
        text: "feature reply here",
        url: URL(string: "https://x.com/carol/status/10")!, kind: .reply
    )
    let repostTweet = Tweet(
        id: "11", authorHandle: "carol",
        text: "feature repost here",
        url: URL(string: "https://x.com/carol/status/11")!, kind: .repost
    )

    // Rule that excludes replies
    let noReplyRule = MonitorRule(
        name: "NoReply", accountHandle: "carol",
        triggerMode: .keywords,
        includeKeywords: ["feature"],
        keywordMatchMode: .any,
        includeReplies: false,
        includeReposts: true
    )
    if matcher.evaluate(tweet: replyTweet, rule: noReplyRule) != nil {
        return "reply should be filtered when includeReplies=false"
    }
    if matcher.evaluate(tweet: repostTweet, rule: noReplyRule) == nil {
        return "repost should pass when includeReposts=true"
    }

    // Rule that excludes reposts
    let noRepostRule = MonitorRule(
        name: "NoRepost", accountHandle: "carol",
        triggerMode: .keywords,
        includeKeywords: ["feature"],
        keywordMatchMode: .any,
        includeReplies: true,
        includeReposts: false
    )
    if matcher.evaluate(tweet: repostTweet, rule: noRepostRule) != nil {
        return "repost should be filtered when includeReposts=false"
    }
    if matcher.evaluate(tweet: replyTweet, rule: noRepostRule) == nil {
        return "reply should pass when includeReplies=true"
    }

    // Account mismatch
    let wrongAccount = MonitorRule(
        name: "Wrong", accountHandle: "other",
        triggerMode: .keywords,
        includeKeywords: ["feature"],
        keywordMatchMode: .any
    )
    if matcher.evaluate(tweet: replyTweet, rule: wrongAccount) != nil {
        return "wrong account should not match"
    }

    return nil
}

@MainActor
func checkEventPruning() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = JSONFileStore(baseDirectory: tempDir)
    let repo = EventRepository(store: store, maxEvents: 5, retentionDays: 30)

    // Add 10 events -> should be pruned to 5
    for i in 0..<10 {
        let event = NotificationEvent(
            id: "evt-\(i)", tweetID: "t\(i)", authorHandle: "user",
            title: "Test", body: "Body \(i)",
            tweetURL: URL(string: "https://x.com/user/status/\(i)")!,
            matchedRuleIDs: [], matchedKeywords: []
        )
        await repo.appendEvent(event)
    }

    let events = await repo.loadEvents()
    if events.count > 5 { return "events not pruned to maxEvents: got \(events.count)" }
    // Most recent should be kept
    if events.last?.id != "evt-9" { return "most recent event not kept" }

    return nil
}

@MainActor
func checkFetchDiagnostics() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = JSONFileStore(baseDirectory: tempDir)
    let history = FetchHistoryRepository(store: store, maxRecords: 20)
    let timeline = MockTimelineProvider()
    let macos = MockNotificationChannel(id: .macOS)
    let telegram = MockNotificationChannel(id: .telegram)
    let gateway = makeGateway(macos: macos, telegram: telegram)
    let pipeline = MonitoringPipeline(
        router: XTimelineRouter(
            webViewProvider: timeline,
            healthTracker: InstanceHealthTracker()
        ),
        ruleEngine: RuleEngine(),
        eventRepository: EventRepository(store: store),
        notificationGateway: gateway,
        fetchHistoryRepository: history
    )
    let rule = MonitorRule(
        name: "Feature rule",
        accountHandle: "testuser",
        triggerMode: .keywords,
        includeKeywords: ["feature"],
        notificationChannels: [.macOS]
    )

    let baseline = await pipeline.runCheck(
        reason: .manual,
        rules: [rule],
        accountCursors: ["testuser": .empty],
        sourceSettings: legacyPipelineSourceSettings
    )
    let baselineRecords = await history.loadRecords()
    if baselineRecords.count != 2 || baselineRecords.contains(where: { $0.outcome != .baseline }) {
        return "baseline fetch records were not persisted correctly"
    }

    await timeline.setTweets(MockTimelineProvider.defaultTweets + [
        Tweet(
            id: "diagnostic-new",
            authorHandle: "testuser",
            text: "A new feature is ready",
            url: URL(string: "https://x.com/testuser/status/diagnostic-new")!,
            publishedAt: Date().addingTimeInterval(60),
            kind: .original
        ),
        Tweet(
            id: "diagnostic-historical",
            authorHandle: "testuser",
            text: "An older tweet without keywords",
            url: URL(string: "https://x.com/testuser/status/diagnostic-historical")!,
            publishedAt: Date().addingTimeInterval(-3_600),
            kind: .reply
        )
    ])
    _ = await pipeline.runCheck(
        reason: .manual,
        rules: [rule],
        accountCursors: baseline.accountCursors,
        sourceSettings: legacyPipelineSourceSettings
    )

    let records = await history.loadRecords()
    if records.filter({ $0.tweetID != nil }).count != 4 {
        return "diagnostic history should contain 4 unique tweets, got \(records.count)"
    }
    if Set(records.compactMap(\.tweetID)).count != records.compactMap(\.tweetID).count {
        return "diagnostic history contains duplicate Tweet IDs"
    }
    guard let matched = records.first(where: { $0.tweetID == "diagnostic-new" }) else {
        return "new tweet diagnostic record missing"
    }
    if matched.outcome != .matched ||
        matched.matchedRuleNames != ["Feature rule"] ||
        matched.matchedKeywords != ["feature"] {
        return "matched diagnostic details are incorrect"
    }
    guard let historical = records.first(where: {
        $0.tweetID == "diagnostic-historical"
    }) else {
        return "older newly discovered tweet record missing"
    }
    // §6.2：`lastSuccessfulFetchAt` 不再是通知门槛——三天窗口内未见 ID
    // 参与规则判断；该推文不含关键词，因此是 notMatched 而非跳过。
    if historical.outcome != .notMatched {
        return "window-in unseen tweet should be evaluated, not gated: \(historical.outcome)"
    }

    let repeatedError = "X 页面没有加载出推文"
    await history.appendRecords([
        FetchRecord(accountHandle: "testuser", message: repeatedError),
        FetchRecord(accountHandle: "testuser", message: repeatedError)
    ])
    let recordsWithFailures = await history.loadRecords()
    if recordsWithFailures.filter({
        $0.outcome == .fetchFailed && $0.text == repeatedError
    }).count != 1 {
        return "identical polling failures should be collapsed into one diagnostic row"
    }

    await history.appendRecords([
        FetchRecord(
            tweet: Tweet(
                id: "expired-diagnostic",
                authorHandle: "testuser",
                text: "Too old",
                url: URL(string: "https://x.com/testuser/status/expired-diagnostic")!,
                publishedAt: Date().addingTimeInterval(-4 * 24 * 60 * 60),
                kind: .original
            ),
            accountHandle: "testuser",
            outcome: .historical
        )
    ])
    if await history.loadRecords().contains(where: {
        $0.tweetID == "expired-diagnostic"
    }) {
        return "diagnostic records older than 3 days were not pruned"
    }
    return nil
}

func checkTimelineAuthorFiltering() -> String? {
    let records = [
        RawTweetDOMRecord(
            id: "1",
            url: "https://x.com/thsottiaux/status/1",
            authorHandle: "thsottiaux",
            text: "Target reply",
            publishedAt: nil,
            isPinned: false,
            hasSocialContext: true,
            replyingToText: "Replying to @giffmana"
        ),
        RawTweetDOMRecord(
            id: "2",
            url: "https://x.com/giffmana/status/2",
            authorHandle: "giffmana",
            text: "Conversation parent",
            publishedAt: nil,
            isPinned: false,
            hasSocialContext: false,
            replyingToText: nil
        ),
        RawTweetDOMRecord(
            id: "3",
            url: "https://x.com/giffmana/status/3",
            authorHandle: "giffmana",
            text: "Other participant reply",
            publishedAt: nil,
            isPinned: false,
            hasSocialContext: true,
            replyingToText: "Replying to @thsottiaux"
        )
    ]
    let request = TimelineRequest(
        accountHandle: "thsottiaux",
        includeReplies: true,
        includeReposts: false,
        maximumCount: 50
    )
    let tweets = WebViewTimelineProvider.filteredTweets(from: records, request: request)
    if tweets.map(\.id) != ["1"] {
        return "expected only target-authored tweet, got IDs \(tweets.map(\.id))"
    }

    let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
    let orderedRecords = (1...12).map { index in
        RawTweetDOMRecord(
            id: "\(index)",
            url: "https://x.com/thsottiaux/status/\(index)",
            authorHandle: "thsottiaux",
            text: "Tweet \(index)",
            publishedAt: ISO8601DateFormatter().string(
                from: baseDate.addingTimeInterval(Double(index))
            ),
            isPinned: false,
            hasSocialContext: false,
            replyingToText: nil
        )
    }
    let limitedRequest = TimelineRequest(
        accountHandle: "thsottiaux",
        includeReplies: true,
        excludedTweetIDs: ["12"],
        maximumCount: 10
    )
    let limitedTweets = WebViewTimelineProvider.filteredTweets(
        from: orderedRecords.shuffled(),
        request: limitedRequest
    )
    if limitedTweets.map(\.id) != ["11", "10", "9", "8", "7", "6", "5", "4", "3"] {
        return "recent ordering/limit/exclusion wrong: \(limitedTweets.map(\.id))"
    }

    let now = Date()
    let freshnessRecords = [
        RawTweetDOMRecord(
            id: "recent",
            url: "https://x.com/thsottiaux/status/recent",
            authorHandle: "thsottiaux",
            text: "Recent tweet",
            publishedAt: ISO8601DateFormatter().string(
                from: now.addingTimeInterval(-2 * 24 * 60 * 60)
            ),
            isPinned: false,
            hasSocialContext: false,
            replyingToText: nil
        ),
        RawTweetDOMRecord(
            id: "expired",
            url: "https://x.com/thsottiaux/status/expired",
            authorHandle: "thsottiaux",
            text: "Expired tweet",
            publishedAt: ISO8601DateFormatter().string(
                from: now.addingTimeInterval(-4 * 24 * 60 * 60)
            ),
            isPinned: false,
            hasSocialContext: false,
            replyingToText: nil
        ),
        RawTweetDOMRecord(
            id: "unknown-date",
            url: "https://x.com/thsottiaux/status/unknown-date",
            authorHandle: "thsottiaux",
            text: "Unknown date",
            publishedAt: nil,
            isPinned: false,
            hasSocialContext: false,
            replyingToText: nil
        )
    ]
    let freshnessRequest = TimelineRequest(
        accountHandle: "thsottiaux",
        includeReplies: true,
        earliestPublishedAt: now.addingTimeInterval(-3 * 24 * 60 * 60),
        maximumCount: 10
    )
    let freshTweets = WebViewTimelineProvider.filteredTweets(
        from: freshnessRecords,
        request: freshnessRequest
    )
    if freshTweets.map(\.id) != ["recent"] {
        return "3-day validity filter returned IDs \(freshTweets.map(\.id))"
    }
    return nil
}

func checkPersistentLoginCookieDetection() -> String? {
    func cookie(name: String, domain: String, expires: Date?) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: "redacted-test-value",
            .domain: domain,
            .path: "/",
            .secure: true
        ]
        if let expires {
            properties[.expires] = expires
        }
        return HTTPCookie(properties: properties)
    }

    let valid = cookie(
        name: "auth_token",
        domain: ".x.com",
        expires: Date().addingTimeInterval(3_600)
    )
    let expired = cookie(
        name: "auth_token",
        domain: ".x.com",
        expires: Date().addingTimeInterval(-3_600)
    )
    let unrelated = cookie(
        name: "auth_token",
        domain: ".example.com",
        expires: Date().addingTimeInterval(3_600)
    )

    guard let valid, let expired, let unrelated else {
        return "failed to construct test cookies"
    }
    if !XSession.hasValidAuthenticationCookie(in: [valid]) {
        return "valid persistent X authentication cookie was not detected"
    }
    if XSession.hasValidAuthenticationCookie(in: [expired, unrelated]) {
        return "expired or unrelated cookies must not restore login"
    }
    return nil
}

// MARK: - Runner

// TASK-01 / §12.1: 配置 v1 → v2 无损迁移
@MainActor
func checkConfigMigrationV2() async -> String? {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let v1JSON = """
    {
      "schemaVersion": 1,
      "pollInterval": 60,
      "runCheckAtLaunch": true,
      "runCheckAfterWake": true,
      "launchAtLogin": true,
      "historyRetentionDays": 45,
      "maxRecentEvents": 100,
      "webViewProviderAcknowledged": true,
      "macOSNotificationsEnabled": true,
      "macOSNotificationSoundEnabled": false,
      "telegramEnabled": true,
      "rules": [
        {
          "id": "C1A2B3C4-D5E6-F708-9101-112131415161",
          "name": "Elon 词",
          "accountHandle": "elonmusk",
          "enabled": true,
          "triggerMode": "keywords",
          "includeKeywords": ["Starship", "launch"],
          "excludeKeywords": ["NASA"],
          "keywordMatchMode": "any",
          "caseSensitive": false,
          "includeReplies": false,
          "includeReposts": true,
          "notificationChannels": ["macOS", "telegram"],
          "createdAt": "2026-07-01T00:00:00Z",
          "updatedAt": "2026-07-02T00:00:00Z"
        }
      ]
    }
    """
    let configURL = tempDir.appendingPathComponent("config.json")
    try? v1JSON.write(to: configURL, atomically: true, encoding: .utf8)

    let repo = ConfigurationRepository(store: JSONFileStore(baseDirectory: tempDir))

    // 第一次 load：字段无损，且被标记为 xWebOnly + 未完成信源配置。
    let first = await repo.load()
    if first.rules.count != 1 { return "v1 rules lost: \(first.rules.count)" }
    if first.rules[0].accountHandle != "elonmusk" { return "rule handle changed" }
    if first.rules[0].name != "Elon 词" { return "rule name changed" }
    if first.rules[0].notificationChannels != [.macOS, .telegram] { return "notification channels lost" }
    if first.rules[0].includeReposts != true { return "includeReposts lost" }
    if first.pollInterval != .oneMinute { return "v1 oneMinute interval not decoded" }
    if first.telegramEnabled != true { return "telegram setting lost" }
    if first.historyRetentionDays != 45 || first.maxRecentEvents != 100 { return "history settings lost" }
    if first.launchAtLogin != true { return "launchAtLogin lost" }
    if first.macOSNotificationSoundEnabled != false { return "macOS sound setting lost" }
    if first.xSourceSettings.policy != .xWebOnly { return "v1 migration must set policy = .xWebOnly" }
    if first.xSourceSettings.sourceSetupCompleted != false { return "v1 migration must block scheduling" }

    // 第二次 load：schemaVersion 已写回 2，规则仍保留。
    let second = await repo.load()
    if second.schemaVersion != 2 { return "schemaVersion not rewritten to 2" }
    if second.rules.count != 1 { return "rules lost after schema bump" }

    return nil
}

// TASK-01: §4.3 一分钟仅保留解码、不再可选；§4.4 实例 URL 校验
func checkConfigSelectableAndInstanceValidation() -> String? {
    if PollingInterval.selectableCases.contains(.oneMinute) {
        return "1 分钟不应出现在 UI 可选间隔中"
    }
    if PollingInterval.selectableCases.count != 4 { return "selectable intervals count wrong" }

    func normalize(_ input: String) -> Result<String, RSSHubInstanceValidationError> {
        RSSHubInstanceValidator.normalize(input)
    }

    // 合法用例
    switch normalize("  https://rsshub.app  ") {
    case .success(let out) where out == "https://rsshub.app": break
    case .success(let out): return "前后空格规范化失败: '\(out)'"
    case .failure(let e): return "合法 URL 被拒: \(e)"
    }
    switch normalize("https://rsshub.app/") {
    case .success(let out) where out == "https://rsshub.app": break
    case .success(let out): return "尾部斜杠未去除: '\(out)'"
    case .failure(let e): return "合法 URL 被拒: \(e)"
    }
    switch normalize("http://localhost:1200") {
    case .success(let out) where out == "http://localhost:1200": break
    case .success(let out): return "localhost 规范化异常: '\(out)'"
    case .failure(let e): return "localhost 被拒: \(e)"
    }
    switch normalize("http://127.0.0.1:4311") {
    case .success: break
    case .failure(let e): return "127.0.0.1 被拒: \(e)"
    }

    // 非法用例 → 各类错误
    func reject(_ input: String, _ want: RSSHubInstanceValidationError) -> String? {
        switch normalize(input) {
        case .success(let out):
            return "应拒绝 '\(input)' 却通过: '\(out)'"
        case .failure(let err):
            return err == want ? nil : "错误类型不符 '\(input)': \(err) != \(want)"
        }
    }
    for (input, want) in [
        ("http://feeds.example.com", RSSHubInstanceValidationError.unsupportedScheme),
        ("https://user:pass@rsshub.app", .containsCredentials),
        ("https://rsshub.app/#frag", .containsFragment),
        ("https://rsshub.app/feed?a=1", .containsQuery),
        ("", .missingHost),
        ("https://", .missingHost)
    ] {
        if let e = reject(input, want) { return e }
    }
    return nil
}

// MARK: - TASK-03: RSS/Atom Parser（DESIGN-RSSHUB.md §5.3–5.5）

/// 生成落在 spec 内的 Snowflake 推文 ID（时间 = 目标时刻）。
func makeSnowflakeID(at date: Date) -> UInt64 {
    let epochMs: UInt64 = 1288834974657
    let ms = UInt64(date.timeIntervalSince1970 * 1000)
    return ms >= epochMs ? (ms - epochMs) << 22 : 0
}

func parseFeed(_ xml: String) throws -> RSSParseResult {
    try XRSSParser.parse(
        data: Data(xml.utf8),
        requestHandle: "agenttest",
        maximumCount: 10,
        now: .init()
    )
}

// RSS 2.0：回复/转发前缀、author.name、去重、无效 link、无日期、媒体空正文
func checkRSSFeedRSS2() -> String? {
    let now = Date()
    let replyID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-60)))
    let repostID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-120)))
    let mediaID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-180)))
    let placeholderID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-240)))
    let dupID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-300)))
    let staleID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-20 * 24 * 3600))) // 三天窗口外

    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>Subject</title>
    <item>
      <title>↩️@someone 这是回复 &amp;<b>加粗</b></title>
      <link>https://x.com/agenttest/status/\(replyID)</link>
      <guid>tag:rsshub,2026:\(replyID)</guid>
      <pubDate>Mon, 06 Jan 2025 10:00:00 +0000</pubDate>
      <author>显示名甲</author>
    </item>
    <item>
      <title>🔁@someone 转发这条</title>
      <link>https://x.com/agenttest/status/\(repostID)</link>
      <pubDate>Tue, 07 Jan 2025 10:00:00 +0000</pubDate>
    </item>
    <item>
      <title></title>
      <link>https://x.com/agenttest/status/\(mediaID)</link>
      <description><![CDATA[<p>&nbsp;转载自「测试」&nbsp;与 &amp;amp;兄弟</p>]]></description>
      <pubDate>Wed, 08 Jan 2025 10:00:00 +0000</pubDate>
    </item>
    <item>
      <title></title>
      <link>https://x.com/agenttest/status/\(placeholderID)</link>
      <pubDate>Wed, 08 Jan 2025 11:00:00 +0000</pubDate>
    </item>
    <item>
      <title>署名应为请求 handle 而非显示名</title>
      <link>https://x.com/agenttest/status/\(dupID)</link>
      <author>Elon 展示</author>
      <pubDate>Thu, 09 Jan 2025 10:00:00 +0000</pubDate>
    </item>
    <item>
      <title>重复 ID 应被去重（第二份）</title>
      <link>https://x.com/agenttest/status/\(dupID)</link>
      <author>造成重复</author>
      <pubDate>Thu, 09 Jan 2025 10:00:00 +0000</pubDate>
    </item>
    <item>
      <title>无效状态 ID 必须丢弃</title>
      <link>https://x.com/agenttest/status/notanumber</link>
      <pubDate>Fri, 10 Jan 2025 10:00:00 +0000</pubDate>
    </item>
    <item>
      <title>三天外的条目应被过滤</title>
      <link>https://x.com/agenttest/status/\(staleID)</link>
      <pubDate>Mon, 01 Jan 2024 10:00:00 +0000</pubDate>
    </item>
    </channel></rss>
    """
    guard let result = try? XRSSParser.parse(
        data: Data(xml.utf8),
        requestHandle: "agenttest",
        maximumCount: 10,
        now: now
    ) else {
        do {
            _ = try XRSSParser.parse(
                data: Data(xml.utf8),
                requestHandle: "agenttest",
                maximumCount: 10,
                now: now
            )
            return "RSS 解析失败（无异常兜底）"
        } catch {
            return "RSS 解析失败: \(error)-\(error.localizedDescription)"
        }
    }

    // 有效条目 5：reply、repost、media、placeholder、dup（无效丢弃、三天外过滤、重复去重）
    if result.tweets.count != 5 { return "RSS 有效条数=\(result.tweets.count)，期望 5" }
    // rawItemCount 是过滤前的原始条数：reply/repost/media/placeholder/dup/stale = 6
    if result.rawItemCount != 6 { return "rawItemCount=\(result.rawItemCount)，期望 6（不随三天窗口/去重内减少错误计数）" }

    // 回顶（publishedAt 倒序，时间相同按数值 ID 倒序）
    if result.tweets[0].kind != .reply || result.tweets[0].id != String(replyID) {
        return "最高应为最近回复 replyID，实际 id=\(result.tweets[0].id) kind=\(result.tweets[0].kind)"
    }

    // 回复类型与内容清洗/去实体
    guard let reply = result.tweets.first(where: { $0.id == String(replyID) }) else {
        return "缺少回复条目 replyID=\(replyID)"
    }
    if reply.kind != .reply { return "回复 kind 应=.reply" }
    if !reply.text.contains("@someone") { return "回复前缀未移除: \(reply.text)" }
    if reply.text.contains("↩️") { return "回复前缀残留" }
    if reply.text.contains("<b>") || reply.text.contains("&amp;") { return "HTML 未清洗: \(reply.text)" }

    // 转发类型与自动 handle
    guard let repost = result.tweets.first(where: { $0.id == String(repostID) }) else {
        return "缺少转发 repostID=\(repostID)"
    }
    if repost.kind != .repost { return "转发 kind 应=.repost" }
    if repost.authorHandle != "agenttest" { return "authorHandle 未用请求 handle: \(repost.authorHandle)" }

    // 媒体推文：CDATA 正文去标签/双解码/空白归一化
    guard let media = result.tweets.first(where: { $0.id == String(mediaID) }) else {
        return "缺少媒体条目 mediaID=\(mediaID)"
    }
    if media.text.contains("<") || media.text.contains("&amp;") || media.text.contains("\u{A0}") {
        return "CDATA HTML 未清洗: \(media.text)"
    }
    if !media.text.contains("转载自「测试」") { return "CDATA 文本丢失: '\(media.text)'" }

    // 空正文占位
    guard let placeholder = result.tweets.first(where: { $0.id == String(placeholderID) }) else {
        return "缺少空正文条目 placeholderID=\(placeholderID)"
    }
    if placeholder.text != "发布了一条媒体推文" {
        return "空正文未使用占位文案: '\(placeholder.text)'"
    }

    // 去重：dupID 只能出现一次
    let dups = result.tweets.filter { $0.id == String(dupID) }
    if dups.count != 1 { return "重复 ID 未去重，出现 \(dups.count) 次" }

    // 显示名不污染 handle
    if let dup = dups.first, dup.authorHandle != "agenttest" {
        return "author.name 污染 handle: \(dup.authorHandle)"
    }

    return nil
}

// Atom：entry 字段映射、CDATA、乱序、url 统一 host、pubDate 缺失时用 Snowflake
func checkRSSFeedAtom() -> String? {
    let now = Date()
    let firstID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-10)))
    let secondID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-20)))
    let thirdID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-30)))

    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom">
      <title>Subject</title>
      <entry>
        <title>🔁@someone 引用转发的旧推</title>
        <id>tag:rsshub,2026:\(firstID)</id>
        <link href="https://twitter.com/agenttest/status/\(firstID)"/>
        <published>2020-01-01T00:00:00Z</published>
        <content type="html">&lt;p&gt;引用内容&lt;/p&gt;</content>
        <author><name>阿奇</name></author>
      </entry>
      <entry>
        <title>第二条 Atom 正文</title>
        <link rel="alternate" href="https://x.com/agenttest/status/\(secondID)"/>
        <updated>2026-08-05T12:00:00.000Z</updated>
        <author><name>贝塔</name></author>
      </entry>
      <entry>
        <title>第三条（无日期，靠 Snowflake）</title>
        <link rel="alternate" href="https://x.com/agenttest/status/\(thirdID)"/>
        <author><name>伽马</name></author>
      </entry>
    </feed>
    """
    guard let result = try? XRSSParser.parse(
        data: Data(xml.utf8),
        requestHandle: "agenttest",
        maximumCount: 10,
        now: now
    ) else { return "Atom 解析失败" }

    if result.tweets.count != 3 { return "Atom 有效条数=\(result.tweets.count)，期望 3" }

    // Snowflake 时间优先于旧 RSS 日期（转发场景）
    guard let first = result.tweets.first(where: { $0.id == String(firstID) }) else {
        return "缺少 Atom 第一条"
    }
    if first.kind != .repost { return "Atom 转发 kind 应=.repost" }
    if first.publishedAt == nil { return "Atom 第一条无时间" }
    if let publishedAt = first.publishedAt,
       publishedAt.timeIntervalSince(now) < -3600 {
        return "未用 Snowflake 时间（旧 RSS 日期被采用）: \(publishedAt)"
    }

    // url host 统一为 x.com
    if !(first.url.absoluteString.hasPrefix("https://x.com/agenttest/status/")) {
        return "Atom url 未统一 host: \(first.url.absoluteString)"
    }

    // 无日期的第三条靠 Snowflake 时间补全
    guard let third = result.tweets.first(where: { $0.id == String(thirdID) }) else {
        return "缺少 Atom 第三条"
    }
    if third.publishedAt == nil { return "Atom 第三条（无 pubDate）没有时间" }

    // 排序：第一（-10s）最晚
    if result.tweets[0].id != String(firstID) {
        return "Atom 未按时间倒序: 首个=\(result.tweets[0].id)"
    }

    return nil
}

// 安全限制：超大响应、外部实体不可加载、无日期无 Snowflake 条目丢弃
func checkRSSFeedSafety() -> String? {
    let now = Date()

    // 超大响应（>5MiB）
    let big = Data(repeating: 0x3C, count: 5 * 1024 * 1024 + 1) // '<' * n，非法但体积已超限
    do {
        _ = try XRSSParser.parse(data: big, requestHandle: "agenttest", maximumCount: 10, now: now)
        return "超大响应未拒绝"
    } catch SourceError.responseTooLarge {
        // 预期
    } catch {
        return "超大响应错误类型不符: \(error)"
    }

    // 外部实体：XMLParser 不应解析外部实体（SSRF/XXE）
    let xxe = """
    <?xml version="1.0"?>
    <!DOCTYPE feed [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
    <rss version="2.0"><channel><item>
      <title>&xxe;</title>
      <link>https://x.com/agenttest/status/12345</link>
      <pubDate>Mon, 06 Jan 2025 10:00:00 +0000</pubDate>
    </item></channel></rss>
    """
    do {
        let result = try XRSSParser.parse(
            data: Data(xxe.utf8),
            requestHandle: "agenttest",
            maximumCount: 10,
            now: now
        )
        // 外部实体不应被加载：要么解析失败（invalidFeed），要么内容中不出现 /etc/passwd
        let joined = result.tweets.map(\.text).joined()
        if joined.contains("root:") { return "外部实体被加载（XXE 漏洞）" }
        if joined.contains("xxe") { return "外部实体被展开: \(joined)" }
    } catch SourceError.invalidFeed {
        // 合法：拒绝解析外部实体
    } catch {
        return "XXE 错误类型不符: \(error)"
    }

    // 无日期且 Snowflake 不可用（id 落在未来 > 5min，超出合理窗口）→ 丢弃
    let futureID = makeSnowflakeID(at: now.addingTimeInterval(600))
    let noDate = """
    <rss version="2.0"><channel><item>
      <title>没有日期也没有有效 ID</title>
      <link>https://x.com/agenttest/status/\(futureID)</link>
    </item></channel></rss>
    """
    guard let noDateResult = try? XRSSParser.parse(
        data: Data(noDate.utf8),
        requestHandle: "agenttest",
        maximumCount: 10,
        now: now
    ) else { return "无日期 Feed 不应解析失败（应返回空结果）" }
    if !noDateResult.tweets.isEmpty { return "无日期条目未被丢弃" }
    if noDateResult.rawItemCount != 0 { return "无日期条目计入 rawItemCount" }

    // 十条上限与时间倒序（§12.5：每轮每账号最多十条，并按发推时间倒序）
    var items = ""
    for i in 0..<12 {
        let id = makeSnowflakeID(at: now.addingTimeInterval(-Double(i) * 60))
        items += """
        <item>
          <title>item \(i)</title>
          <link>https://x.com/agenttest/status/\(id)</link>
          <pubDate>Mon, 06 Jan 2025 10:00:00 +0000</pubDate>
        </item>
        """
    }
    let capFeed = "<rss version=\"2.0\"><channel><title>T</title>\(items)</channel></rss>"
    guard let capResult = try? XRSSParser.parse(
        data: Data(capFeed.utf8),
        requestHandle: "agenttest",
        maximumCount: 10,
        now: now
    ) else { return "12 条 Feed 解析失败" }
    if capResult.tweets.count != 10 { return "最多返回 10 条，实际 \(capResult.tweets.count)" }
    if capResult.rawItemCount != 12 { return "rawItemCount 应为原始 12 条，实际 \(capResult.rawItemCount)" }
    let dates = capResult.tweets.compactMap(\.publishedAt)
    if dates != dates.sorted(by: >) { return "结果未按发推时间倒序" }

    return nil
}

// MARK: - TASK-04: RSSHub 路由、HTTP 与实例健康（DESIGN-RSSHUB.md §5.1、§5.2、§7.2、§12.3）

func checkRSSHubRequestBuilder() -> String? {
    let builder = RSSHubRequestBuilder()
    do {
        let url = try builder.makeURL(
            baseURL: "https://rsshub.app",
            handle: "elonmusk",
            includeReplies: true,
            includeReposts: false,
            maximumCount: 10
        )
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "URLComponents 解析失败"
        }
        guard components.path == "/twitter/user/elonmusk/includeReplies=1&includeRts=0&count=10&showEmojiForRetweetAndReply=1&showSymbolForRetweetAndReply=0&showQuotedInTitle=0" else {
            return "路由参数映射错误: \(components.path)"
        }
        guard components.host == "rsshub.app" else { return "host 错误" }

        // count=min(maximumCount, 10)
        let url20 = try builder.makeURL(
            baseURL: "https://rsshub.app",
            handle: "alice",
            includeReplies: false,
            includeReposts: true,
            maximumCount: 20
        )
        if !url20.path.contains("count=10") { return "count 未封顶 10: \(url20.path)" }

        // handle 需编码（如带下划线正常、URL 特殊字符拒绝走校验）
        let urlHandle = try builder.makeURL(
            baseURL: "https://rsshub.app",
            handle: "a_b-c",
            includeReplies: false,
            includeReposts: false,
            maximumCount: 10
        )
        if !urlHandle.path.contains("/twitter/user/a_b-c/") { return "handle 拼接异常" }
    } catch {
        return "请求构造抛错: \(error)"
    }

    // 非法实例
    do {
        _ = try builder.makeURL(
            baseURL: "http://insecure.example.com",
            handle: "alice",
            includeReplies: false,
            includeReposts: false,
            maximumCount: 10
        )
        return "非 https 且非 localhost 实例未被拒绝"
    } catch SourceError.invalidInstanceURL {
    } catch {
        return "非法实例错误类型不符: \(error)"
    }
    do {
        _ = try builder.makeURL(
            baseURL: "https://user:pass@rsshub.app",
            handle: "alice",
            includeReplies: false,
            includeReposts: false,
            maximumCount: 10
        )
        return "含凭据实例未被拒绝"
    } catch SourceError.invalidInstanceURL {
    } catch {
        return "含凭据实例错误类型不符: \(error)"
    }
    return nil
}

func makeRSSHubClient(expectedHosts: Set<String> = []) -> RSSHubHTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: expectedHosts)
}

func rssHubFixture(now: Date, handle: String = "agenttest", offsetSeconds: Int = -30) -> Data {
    let id = makeSnowflakeID(at: now.addingTimeInterval(TimeInterval(offsetSeconds)))
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>Subject</title>
    <item>
      <title>原创正文</title>
      <link>https://x.com/\(handle)/status/\(id)</link>
      <pubDate>Mon, 06 Jan 2025 10:00:00 +0000</pubDate>
    </item>
    </channel></rss>
    """
    return Data(xml.utf8)
}

func checkRSSHubHTTPClientAndFallback() async -> String? {
    let now = Date()

    // 1. 304 → .notModified
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 304, httpVersion: nil, headerFields: ["ETag": "\"abc\""]
        )!
        return (response, Data())
    }
    let client304 = makeRSSHubClient()
    let request304 = URLRequest(url: URL(string: "https://rsshub.app/twitter/user/x")!)
    do {
        let result = try await client304.get(request: request304)
        if !result.notModified { return "304 未映射为 notModified" }
        if result.eTag != "\"abc\"" { return "ETag 未透传" }
    } catch {
        return "304 抛错: \(error)"
    }

    // 2. 429 + Retry-After → .rateLimited(retryAfter)
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 429, httpVersion: nil,
            headerFields: ["Retry-After": "900"]
        )!
        return (response, Data())
    }
    let client429 = makeRSSHubClient()
    do {
        _ = try await client429.get(request: URLRequest(url: URL(string: "https://rsshub.app/x")!))
        return "429 未抛错"
    } catch SourceError.rateLimited(let provider, let retryAfter) {
        if provider != .rssHub { return "429 provider 错误" }
        guard let retryAfter else { return "429 Retry-After 未解析" }
        let remaining = retryAfter.timeIntervalSince(Date())
        if remaining < 890 || remaining > 910 { return "429 Retry-After 秒数不对: \(remaining)" }
    } catch {
        return "429 错误类型不符: \(error)"
    }

    // 3. 5xx → networkUnavailable（禁止映射成 pageStructureChanged）
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    let client500 = makeRSSHubClient()
    do {
        _ = try await client500.get(request: URLRequest(url: URL(string: "https://rsshub.app/x")!))
        return "5xx 未抛错"
    } catch SourceError.networkUnavailable(let provider) {
        if provider != .rssHub { return "5xx provider 错误" }
    } catch {
        return "5xx 错误类型不符: \(error)"
    }

    // 4. 404 → accountUnavailable
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    let client404 = makeRSSHubClient()
    do {
        _ = try await client404.get(request: URLRequest(url: URL(string: "https://rsshub.app/x")!))
        return "404 未抛错"
    } catch SourceError.accountUnavailable(let code) {
        if code != 404 { return "404 statusCode 错误" }
    } catch {
        return "404 错误类型不符: \(error)"
    }

    // 5. 重定向到 x.com → 拒绝并报告 .redirectRejected（§5.2、§12.3）
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": "https://x.com/agenttest"]
        )!
        return (response, Data())
    }
    let clientRedirect = makeRSSHubClient(expectedHosts: ["rsshub.app"])
    do {
        _ = try await clientRedirect.get(request: URLRequest(url: URL(string: "https://rsshub.app/x")!))
        return "重定向到 x.com 未被拒绝"
    } catch SourceError.redirectRejected {
        // 预期：3xx 且未跟随（URLProtocol stub 不自动跟随重定向）→ 如实报告 redirectRejected
    } catch {
        return "重定向拒绝错误类型不符: \(error)"
    }

    // 6. Provider 端到端：实例 A 500 → 实例 B 成功（fallback 由 Router 负责，这里验证 Provider 各自正确）
    let goodFeed = rssHubFixture(now: now)
    var requestCount = 0
    MockURLProtocol.requestHandler = { request in
        requestCount += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["ETag": "\"v1\""])!
        return (response, goodFeed)
    }
    let provider = RSSHubTimelineProvider(
        instanceURL: "https://rsshub.app",
        client: makeRSSHubClient(expectedHosts: ["rsshub.app"])
    )
    let timelineRequest = TimelineRequest(
        accountHandle: "agenttest",
        includeReplies: false,
        includeReposts: false,
        maximumCount: 10
    )
    do {
        let result = try await provider.fetch(timelineRequest)
        if result.providerID != .rssHub { return "providerID 错误" }
        if result.instanceHost != "rsshub.app" { return "instanceHost 错误" }
        if result.rawItemCount != 1 { return "rawItemCount 错误: \(result.rawItemCount)" }
        if result.tweets.count != 1 { return "tweets 数错误" }
        if result.tweets[0].authorHandle != "agenttest" { return "handle 未用请求 handle" }
        if result.feedState != .healthy { return "feedState 应为 healthy" }
    } catch {
        return "Provider 抓取抛错: \(error)"
    }

    // 7. 2xx 空 Feed：Provider 不抛错，rawItemCount=0（Router 在 TASK-05 判定 suspiciousEmpty/emptyUnverified）
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data("<rss version=\"2.0\"><channel><title>T</title></channel></rss>".utf8))
    }
    let emptyProvider = RSSHubTimelineProvider(
        instanceURL: "https://rsshub.app",
        client: makeRSSHubClient(expectedHosts: ["rsshub.app"])
    )
    do {
        let result = try await emptyProvider.fetch(timelineRequest)
        if result.rawItemCount != 0 { return "空 Feed rawItemCount != 0" }
        if result.feedState != .healthy { return "空 Feed feedState 应为 healthy（状态判定在 Router）" }
    } catch {
        return "空 Feed Provider 不应抛错: \(error)"
    }

    return nil
}

/// Mutable clock shared with an `InstanceHealthTracker` to simulate time passing.
final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(seconds)
    }
}

func checkInstanceHealthTracker() async -> String? {
    let clock = LockedClock()
    let tracker = InstanceHealthTracker(now: { clock.now })

    let instances = ["https://a.rsshub.app", "https://b.rsshub.app", "https://c.rsshub.app"]

    // 初始全部可用
    if await tracker.usableInstances(instances).count != 3 { return "初始实例应全部可用" }

    // A 429（带 Retry-After 30s）→ 冷却至 30s
    await tracker.recordFailure("https://a.rsshub.app", cause: .rateLimited(retryAfter: clock.now.addingTimeInterval(30)), error: "429")
    var usable = await tracker.usableInstances(instances)
    if usable.contains("https://a.rsshub.app") { return "429 后 A 仍可用" }
    if usable.count != 2 { return "冷却后可用实例数错误: \(usable)" }

    // 30 秒后恢复
    clock.advance(by: 31)
    usable = await tracker.usableInstances(instances)
    if !usable.contains("https://a.rsshub.app") { return "冷却结束后 A 未恢复" }

    // B 5xx → 冷却 2 分钟
    await tracker.recordFailure("https://b.rsshub.app", cause: .serverError, error: "500")
    usable = await tracker.usableInstances(instances)
    if usable.contains("https://b.rsshub.app") { return "5xx 后 B 仍可用" }
    if !usable.contains("https://a.rsshub.app") { return "A 不应被 B 的故障牵连" }

    // C 成功：恢复 B 后，优先上次成功实例
    await tracker.recordSuccess("https://c.rsshub.app")
    clock.advance(by: 121)
    usable = await tracker.usableInstances(instances)
    if !usable.contains("https://b.rsshub.app") { return "冷却结束后 B 未恢复" }
    if await tracker.usableInstances(instances).first != "https://c.rsshub.app" { return "上次成功实例未排第一: \(await tracker.usableInstances(instances))" }

    // 冷却计数
    let stateC = await tracker.state(of: "https://c.rsshub.app")
    if stateC?.requestCount != 1 { return "C 请求计数错误" }

    return nil
}

// MARK: - TASK-07: Scheduler 抖动、配置门槛与 source-aware backoff（DESIGN-RSSHUB.md §8.2、§8.3）

@MainActor
func makeConfiguredScheduler(
    in dir: URL,
    configured: Bool,
    jitter: Double? = nil,
    feedRules: [MonitorRule] = []
) async -> (PollScheduler, MockMonitoringPipeline, StateRepository) {
    let store = JSONFileStore(baseDirectory: dir)
    if configured {
        await saveConfiguredApp(store, extraRules: feedRules)
    } else if !feedRules.isEmpty {
        // §13：只有 feed 规则时允许在"源配置未完成"状态下检查。
        await saveConfiguredApp(store, sourceSetupCompleted: false, extraRules: feedRules)
    }
    let pipeline = MockMonitoringPipeline()
    let repo = StateRepository(store: store)
    let scheduler: PollScheduler
    if let jitter {
        scheduler = PollScheduler(
            pipeline: pipeline,
            stateRepository: repo,
            configRepository: ConfigurationRepository(store: store),
            jitterSource: { jitter }
        )
    } else {
        scheduler = PollScheduler(
            pipeline: pipeline,
            stateRepository: repo,
            configRepository: ConfigurationRepository(store: store)
        )
    }
    return (scheduler, pipeline, repo)
}

@MainActor
func checkSchedulerJitterAndConfig() async -> String? {
    // 1. 抖动边界（§8.2）
    if abs(PollScheduler.jitteredInterval(base: 300, random: 0) - 240) > 0.001 {
        return "jitter lower bound != 0.8x"
    }
    if abs(PollScheduler.jitteredInterval(base: 300, random: 1) - 360) > 0.001 {
        return "jitter upper bound != 1.2x"
    }
    if abs(PollScheduler.jitteredInterval(base: 300, random: 0.5) - 300) > 0.001 {
        return "jitter mid != base"
    }
    if abs(PollScheduler.jitteredInterval(base: 300, random: 7) - 360) > 0.001 {
        return "jitter should clamp high"
    }
    if abs(PollScheduler.jitteredInterval(base: 300, random: -3) - 240) > 0.001 {
        return "jitter should clamp low"
    }

    // 2. 源配置未完成：禁止自动与手动检查（约束 11）
    let blockedDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: blockedDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: blockedDir) }
    let (blockedScheduler, blockedPipeline, _) = await makeConfiguredScheduler(in: blockedDir, configured: false)
    await blockedScheduler.runCheck(reason: .manual)
    await blockedScheduler.triggerNow(reason: .manual)
    if await blockedPipeline.callCount != 0 {
        return "未完成源配置时应禁止一切检查（手动 + triggerNow）"
    }

    // 2b. 只有自定义 RSS 源规则时：即使信源配置未完成也允许检查（§13）
    let feedGateDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: feedGateDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: feedGateDir) }
    let feedGateRule = MonitorRule(
        name: "feed gate", accountHandle: "news", feedURL: "https://news.example/rss.xml",
        triggerMode: .keywords, includeKeywords: ["a"], notificationChannels: [.macOS]
    )
    let (feedGateSched, feedGatePipe, _) = await makeConfiguredScheduler(
        in: feedGateDir, configured: false, feedRules: [feedGateRule]
    )
    await feedGateSched.runCheck(reason: .manual)
    if await feedGatePipe.callCount != 1 {
        return "存在已启用 feed 规则时应允许检查（源配置未完成）"
    }

    // 3. 完成配置后：手动检查即时执行，不受抖动门控
    let okDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: okDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: okDir) }
    let (okScheduler, okPipeline, _) = await makeConfiguredScheduler(in: okDir, configured: true, jitter: 1.0)
    await okScheduler.runCheck(reason: .manual)
    if await okPipeline.callCount != 1 { return "手动检查应即时执行、不被抖动阻塞" }

    // 3. rateLimited + Retry-After → backoff 到最早可重试时间（§8.3）
    let rlDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: rlDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rlDir) }
    let retryDate = Date().addingTimeInterval(90)
    let (rlSched, rlPipe, rlRepo) = await makeConfiguredScheduler(in: rlDir, configured: true)
    await rlPipe.setNextSummary(
        PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 0,
                       eventsGenerated: 0, loginRequired: false, actionRequired: nil, rateLimited: true,
                       rateLimitedUntil: retryDate, error: nil, isTransientError: false, accountCursors: [:])
    )
    await rlSched.runCheck(reason: .manual)
    let rlState = await rlRepo.load()
    guard let rlBackoff = rlState.backoffUntil else { return "rate-limit 应有 backoff" }
    if abs(rlBackoff.timeIntervalSince(retryDate)) > 5 {
        return "RSSHub 429 应使用 earliest retryable 时间，实际差 \(rlBackoff.timeIntervalSince(retryDate))"
    }

    // 4. rateLimited 无 Retry-After → 默认 15 分钟（X 沿用）
    let rl2Dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: rl2Dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rl2Dir) }
    let (rl2Sched, rl2Pipe, rl2Repo) = await makeConfiguredScheduler(in: rl2Dir, configured: true)
    await rl2Pipe.setNextSummary(
        PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 0,
                       eventsGenerated: 0, loginRequired: false, actionRequired: nil, rateLimited: true,
                       error: nil, isTransientError: false, accountCursors: [:])
    )
    await rl2Sched.runCheck(reason: .manual)
    let rl2State = await rl2Repo.load()
    guard let rl2Backoff = rl2State.backoffUntil else { return "rate-limit 无 Retry-After 也应有 backoff" }
    let delta = rl2Backoff.timeIntervalSince(Date())
    if delta < 13 * 60 || delta > 17 * 60 {
        return "无 Retry-After 时应默认 15 分钟 backoff，实际 \(delta)"
    }

    // 4b. transient → 2 分钟
    let trDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: trDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: trDir) }
    let (trSched, trPipe, trRepo) = await makeConfiguredScheduler(in: trDir, configured: true)
    await trPipe.setNextSummary(
        PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 1, tweetsFound: 0,
                       eventsGenerated: 0, loginRequired: false, actionRequired: nil, rateLimited: false,
                       error: "transient", isTransientError: true, accountCursors: [:])
    )
    await trSched.runCheck(reason: .manual)
    let trState = await trRepo.load()
    guard let trBackoff = trState.backoffUntil else { return "transient 应有 backoff" }
    let trDelta = trBackoff.timeIntervalSince(Date())
    if trDelta < 90 || trDelta > 150 { return "transient 应 backoff 2 分钟，实际 \(trDelta)" }

    // 5. configurationRequired → 不退避、不重试循环
    let crDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: crDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: crDir) }
    let (crSched, crPipe, crRepo) = await makeConfiguredScheduler(in: crDir, configured: true)
    await crPipe.setNextSummary(
        PollRunSummary(startTime: Date(), endTime: Date(), accountsChecked: 0, tweetsFound: 0,
                       eventsGenerated: 0, loginRequired: false, actionRequired: nil, rateLimited: false,
                       error: "需要配置 RSSHub 信源", isTransientError: false,
                       configurationRequired: true, accountCursors: [:])
    )
    await crSched.runCheck(reason: .manual)
    let crState = await crRepo.load()
    if crState.backoffUntil != nil { return "配置缺失时不进入退避" }
    if crState.lastRunSummary?.configurationRequired != true { return "configurationRequired 未持久化" }

    return nil
}

// MARK: - TASK-06: Cursor 语义与去重（DESIGN-RSSHUB.md §6.2、§12.5）

/// 快速构造一个带抓取历史仓库的 Pipeline。
@MainActor
func makeRecordedPipeline(
    webView: MockTimelineProvider,
    factory: @escaping @Sendable (String) -> RSSHubHTTPClient,
    feedProvider: (any RSSDirectFeedProviding)? = nil
) async -> (MonitoringPipeline, FetchHistoryRepository) {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let store = JSONFileStore(baseDirectory: tempDir)
    let history = FetchHistoryRepository(store: store, maxRecords: 100)
    let macos = MockNotificationChannel(id: .macOS)
    let gateway = makeGateway(macos: macos, telegram: MockNotificationChannel(id: .telegram))
    let pipeline = MonitoringPipeline(
        router: XTimelineRouter(
            webViewProvider: webView,
            healthTracker: InstanceHealthTracker(),
            rssHubClientFactory: factory
        ),
        ruleEngine: RuleEngine(),
        eventRepository: EventRepository(store: store),
        notificationGateway: gateway,
        fetchHistoryRepository: history,
        feedProvider: feedProvider
    )
    return (pipeline, history)
}

let rssHubSourceSettings = XSourceSettings(
    policy: .rssHubOnly,
    rssHubInstances: ["https://rsshub.app"],
    webFallbackRiskAcknowledged: false,
    sourceSetupCompleted: true
)

func checkPipelineCursorSemantics() async -> String? {
    let rule = MonitorRule(
        name: "Cursor rule",
        accountHandle: "testuser",
        triggerMode: .keywords,
        includeKeywords: ["feature"],
        keywordMatchMode: .any,
        notificationChannels: [.macOS]
    )
    let now = Date()

    // --- 1. 首次健康（rawItemCount > 0）只建立基线 ---
    let tweets1 = [Tweet(id: "c1-1", authorHandle: "testuser", text: "feature launch",
                         url: URL(string: "https://x.com/testuser/status/c1-1")!,
                         publishedAt: now, kind: .original)]
    let web1 = MockTimelineProvider()
    await web1.setTweets(tweets1)
    let (pipe1, _) = await makeRecordedPipeline(webView: web1) { _ in
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: ["rsshub.app"])
    }
    let s1 = await pipe1.runCheck(
        reason: .manual, rules: [rule],
        accountCursors: ["testuser": .empty],
        sourceSettings: legacyPipelineSourceSettings
    )
    let cursor1 = s1.accountCursors["testuser"]
    if cursor1?.initialized != true { return "首次健康抓取应初始化 Cursor" }
    if cursor1?.seenTweetIDs != ["c1-1"] { return "首次应保存返回的 ID" }
    if s1.eventsGenerated != 0 { return "首次健康抓取不应通知" }

    // 2. 空 Feed：不初始化 Cursor、不推进 lastSuccessfulFetchAt、不推进成功时间
    let emptyXML = Data("<rss version=\"2.0\"><channel><title>T</title></channel></rss>".utf8)
    rssHubRequestStub { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, emptyXML)
    }
    let (pipeEmp, _) = await makeRecordedPipeline(webView: MockTimelineProvider()) { _ in
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: ["rsshub.app"])
    }
    let sEmp = await pipeEmp.runCheck(
        reason: .manual, rules: [rule],
        accountCursors: ["testuser": .empty],
        sourceSettings: rssHubSourceSettings
    )
    guard let cEmpty = sEmp.accountCursors["testuser"] else { return "空 Feed 后应有 Cursor 返回" }
    if cEmpty.initialized { return "首次空 Feed 不得初始化 Cursor" }
    if cEmpty.lastSuccessfulFetchAt != nil { return "空 Feed 不得推进 lastSuccessfulFetchAt" }
    if sEmp.error == nil { return "空 Feed 应报告错误" }

    // 3. 已初始化账号：空 Feed 不推进 lastSuccessfulFetchAt
    let base = AccountCursor(
        seenTweetIDs: ["old"], initialized: true,
        lastCheckedAt: now, lastSuccessfulFetchAt: now, lastErrorCode: nil)
    let sEmp2 = await pipeEmp.runCheck(
        reason: .manual, rules: [rule],
        accountCursors: ["testuser": base],
        sourceSettings: rssHubSourceSettings
    )
    if sEmp2.accountCursors["testuser"]?.lastSuccessfulFetchAt != base.lastSuccessfulFetchAt {
        return "已初始化账号空 Feed 不得推进 lastSuccessfulFetchAt"
    }

    // 4. notModified 视为健康成功
    rssHubRequestStub { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 304,
                                       httpVersion: nil, headerFields: ["ETag": "\"abc\""])!
        return (response, Data())
    }
    let (pipeNM, histNM) = await makeRecordedPipeline(webView: MockTimelineProvider()) { _ in
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: ["rsshub.app"])
    }
    let sNM = await pipeNM.runCheck(
        reason: .manual, rules: [rule],
        accountCursors: ["testuser": .empty],
        sourceSettings: rssHubSourceSettings
    )
    if sNM.error != nil { return "notModified 不应报错" }
    if sNM.accountCursors["testuser"]?.lastSuccessfulFetchAt == nil {
        return "notModified 应推进 lastSuccessfulFetchAt"
    }
    let nmRecords = await histNM.loadRecords()
    if nmRecords.first?.providerID != .rssHub || nmRecords.first?.instanceHost != "rsshub.app" {
        return "FetchRecord 未记录 Provider 来源（schema 4）"
    }

    // 5. 三天窗口内、但早于上次成功抓取的未见 ID 仍触发规则（§6.2：删除那句门槛）
    await web1.setTweets([
        Tweet(id: "delay-new", authorHandle: "testuser", text: "delayed feature post",
              url: URL(string: "https://x.com/testuser/status/delay-new")!,
              publishedAt: now.addingTimeInterval(-3_600), kind: .original)
    ])
    let delayedCursor = AccountCursor(
        seenTweetIDs: ["old"], initialized: true,
        lastCheckedAt: now, lastSuccessfulFetchAt: now.addingTimeInterval(3_600),
        lastErrorCode: nil)
    let sDelay = await pipe1.runCheck(
        reason: .manual, rules: [rule],
        accountCursors: ["testuser": delayedCursor],
        sourceSettings: legacyPipelineSourceSettings
    )
    if sDelay.eventsGenerated != 1 { return "延迟出现的窗口内 ID 应触发通知（收到 \(sDelay.eventsGenerated)）" }

    // 6. 超过三天的未见 ID：只记历史、不通知、仍进入 seen
    await web1.setTweets([
        Tweet(id: "stale-id", authorHandle: "testuser", text: "ancient feature",
              url: URL(string: "https://x.com/testuser/status/stale-id")!,
              publishedAt: now.addingTimeInterval(-4 * 24 * 3_600), kind: .original)
    ])
    let sStale = await pipe1.runCheck(
        reason: .manual, rules: [rule],
        accountCursors: ["testuser": delayedCursor],
        sourceSettings: legacyPipelineSourceSettings
    )
    if sStale.eventsGenerated != 0 { return "超过三天的未见 ID 不得通知" }
    if !(sStale.accountCursors["testuser"]?.seenTweetIDs.contains("stale-id") ?? false) {
        return "超过三天的未见 ID 应加入 seen（避免重复）"
    }

    // 7. 同一 Tweet 在 RSSHub 与 X WebView 间切换不重复通知
    let sid = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-60)))
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel><title>Subject</title>
    <item><title>feature via rss</title><link>https://x.com/testuser/status/\(sid)</link>
    <pubDate>Mon, 06 Jan 2025 10:00:00 +0000</pubDate></item>
    </channel></rss>
    """
    rssHubRequestStub { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data(xml.utf8))
    }
    let (pipeSwitch, _) = await makeRecordedPipeline(webView: web1) { _ in
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: ["rsshub.app"])
    }
    let startCursor = AccountCursor(
        seenTweetIDs: [], initialized: true,
        lastCheckedAt: now, lastSuccessfulFetchAt: now, lastErrorCode: nil)
    let sRss = await pipeSwitch.runCheck(
        reason: .manual, rules: [rule],
        accountCursors: ["testuser": startCursor],
        sourceSettings: rssHubSourceSettings
    )
    if sRss.eventsGenerated != 1 { return "RSSHub 侧首次应通知" }
    await web1.setTweets([
        Tweet(id: String(sid), authorHandle: "testuser", text: "same tweet via webview",
              url: URL(string: "https://x.com/testuser/status/\(sid)")!,
              publishedAt: now, kind: .original)
    ])
    let sX = await pipeSwitch.runCheck(
        reason: .manual, rules: [rule],
        accountCursors: sRss.accountCursors,
        sourceSettings: legacyPipelineSourceSettings
    )
    if sX.eventsGenerated != 0 { return "跨 Provider 已见 Tweet 不得重复通知" }

    // 8. seen IDs 300 上限
    var cur = AccountCursor.empty
    for i in 0..<330 { cur.addTweetID("id-\(i)") }
    if cur.seenTweetIDs.count != 300 { return "seen 应保持 300 上限，实际 \(cur.seenTweetIDs.count)" }
    if cur.seenTweetIDs.first != "id-30" || cur.seenTweetIDs.last != "id-329" {
        return "seen 剪裁应丢弃最旧的保留最新的"
    }

    return nil
}

// MARK: - TASK-05: Router 策略与零 X 流量（DESIGN-RSSHUB.md §12.4）

/// 记录 WebView 调用次数的 mock Provider。
actor CountingWebViewProvider: @preconcurrency TimelineProvider {
    var id: TimelineProviderID = .xWeb
    var fetchCount = 0
    var result: Result<TimelineFetchResult, Error> = .success(
        TimelineFetchResult(
            tweets: MockTimelineProvider.defaultTweets,
            providerID: .xWeb,
            rawItemCount: 2,
            feedState: .healthy
        )
    )

    func setResult(_ newResult: Result<TimelineFetchResult, Error>) async {
        result = newResult
    }

    func fetch(_ request: TimelineRequest) async throws -> TimelineFetchResult {
        fetchCount += 1
        switch result {
        case .success(let value): return value
        case .failure(let error): throw error
        }
    }
}

/// 通过 URLProtocol stub 提供 RSSHub 行为：返回一个绑定 MockURLProtocol 的客户端工厂。
/// 实际响应行为由全局 `MockURLProtocol.requestHandler` 决定（测试按顺序逐一设置）。
func makeRSSHubClientFactory(host: String = "rsshub.app") -> @Sendable (String) -> RSSHubHTTPClient {
    { instanceURL in
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // 与生产 factory 一致：按实例自身的 host 构造白名单（§5.2）。
        let resolvedHost = URL(string: instanceURL)?.host ?? host
        return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: [resolvedHost])
    }
}

func rssHubRequestStub(handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
    MockURLProtocol.requestHandler = { request in
        try handler(request)
    }
}

/// 线程安全的计数器（供 URLSession 后台线程与主测试线程共享）。
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

func checkRouterPolicies() async -> String? {
    let now = Date()
    let goodFeed = rssHubFixture(now: now)

    // 1. rssHubOnly：RSSHub 成功时 WebView 零调用；策略本身也不允许回退
    let webViewA = CountingWebViewProvider()
    rssHubRequestStub { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, goodFeed)
    }
    let routerA = XTimelineRouter(
        webViewProvider: webViewA,
        healthTracker: InstanceHealthTracker(),
        rssHubClientFactory: makeRSSHubClientFactory()
    )
    let settingsOnly = XSourceSettings(
        policy: .rssHubOnly,
        rssHubInstances: ["https://rsshub.app"],
        webFallbackRiskAcknowledged: false,
        sourceSetupCompleted: true
    )
    let request = TimelineRequest(accountHandle: "agenttest", includeReplies: false, includeReposts: false, maximumCount: 10)
    do {
        let result = try await routerA.fetch(request, settings: settingsOnly, cursorInitialized: true)
        if result.providerID != .rssHub { return "rssHubOnly 应返回 rssHub" }
        if result.fallbackFromProviderID != nil { return "rssHubOnly 不应有回退标记" }
        let count = await webViewA.fetchCount
        if count != 0 { return "rssHubOnly 下 WebView 被调用 \(count) 次（违反零 X 流量）" }
    } catch {
        return "rssHubOnly 成功路径抛错: \(error)"
    }

    // 2. rssHubThenXWeb：RSSHub 成功时不调用 WebView
    let webViewB = CountingWebViewProvider()
    let routerB = XTimelineRouter(
        webViewProvider: webViewB,
        healthTracker: InstanceHealthTracker(),
        rssHubClientFactory: makeRSSHubClientFactory()
    )
    let settingsThen = XSourceSettings(
        policy: .rssHubThenXWeb,
        rssHubInstances: ["https://rsshub.app"],
        webFallbackRiskAcknowledged: true,
        sourceSetupCompleted: true
    )
    do {
        let result = try await routerB.fetch(request, settings: settingsThen, cursorInitialized: true)
        if result.providerID != .rssHub { return "rssHubThenXWeb 成功时应来自 rssHub" }
        let count = await webViewB.fetchCount
        if count != 0 { return "RSSHub 成功时不应触发 WebView（count=\(count)）" }
    } catch {
        return "rssHubThenXWeb 成功路径抛错: \(error)"
    }

    // 3. rssHubThenXWeb：RSSHub 全部瞬时失败 → 回退 WebView 恰好一次
    let webViewC = CountingWebViewProvider()
    rssHubRequestStub { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    let routerC = XTimelineRouter(
        webViewProvider: webViewC,
        healthTracker: InstanceHealthTracker(),
        rssHubClientFactory: makeRSSHubClientFactory()
    )
    do {
        let result = try await routerC.fetch(request, settings: settingsThen, cursorInitialized: true)
        if result.providerID != .xWeb { return "回退应返回 xWeb" }
        if result.fallbackFromProviderID != .rssHub { return "回退标记应为 rssHub" }
        let count = await webViewC.fetchCount
        if count != 1 { return "回退应只触发一次 WebView，实际 \(count) 次" }
    } catch {
        return "rssHubThenXWeb 回退路径抛错: \(error)"
    }

    // 4. 回退只允许一次：同一轮内第二个账号再次失败 → 不再回退 WebView
    let webViewD = CountingWebViewProvider()
    let clockD = LockedClock()
    let routerD = XTimelineRouter(
        webViewProvider: webViewD,
        healthTracker: InstanceHealthTracker(now: { clockD.now }),
        rssHubClientFactory: makeRSSHubClientFactory()
    )
    do {
        let first = try await routerD.fetch(request, settings: settingsThen, cursorInitialized: true)
        if first.providerID != .xWeb { return "首次回退应成功" }
        // 推进冷却让 RSSHub 重新可用，验证同一轮内不会再次回退
        clockD.advance(by: 300)
    } catch {
        return "首次回退失败: \(error)"
    }
    do {
        _ = try await routerD.fetch(request, settings: settingsThen, cursorInitialized: true)
        return "同一轮回退已用，再次失败应抛错"
    } catch {
        let count = await webViewD.fetchCount
        if count != 1 { return "同一轮 WebView 回退应仅一次，实际 \(count) 次" }
    }

    // 5. 未确认风险 → 禁止回退（即使 RSSHub 全部失败）
    let webViewE = CountingWebViewProvider()
    let routerE = XTimelineRouter(
        webViewProvider: webViewE,
        healthTracker: InstanceHealthTracker(),
        rssHubClientFactory: makeRSSHubClientFactory()
    )
    let settingsUnacknowledged = XSourceSettings(
        policy: .rssHubThenXWeb,
        rssHubInstances: ["https://rsshub.app"],
        webFallbackRiskAcknowledged: false,
        sourceSetupCompleted: true
    )
    do {
        _ = try await routerE.fetch(request, settings: settingsUnacknowledged, cursorInitialized: true)
        return "未确认风险时不应回退成功"
    } catch {
        let count = await webViewE.fetchCount
        if count != 0 { return "未确认风险时 WebView 不应被调用" }
    }

    // 6. 配置缺失 → configurationRequired，无 WebView
    let webViewF = CountingWebViewProvider()
    let routerF = XTimelineRouter(
        webViewProvider: webViewF,
        healthTracker: InstanceHealthTracker()
    )
    let settingsNoInstances = XSourceSettings(
        policy: .rssHubOnly,
        rssHubInstances: [],
        webFallbackRiskAcknowledged: false,
        sourceSetupCompleted: false
    )
    do {
        _ = try await routerF.fetch(request, settings: settingsNoInstances, cursorInitialized: true)
        return "无实例应抛 configurationRequired"
    } catch SourceError.configurationRequired {
        let count = await webViewF.fetchCount
        if count != 0 { return "配置缺失时不应访问 WebView" }
    } catch {
        return "配置缺失错误类型不符: \(error)"
    }

    // 7. 404（账号不存在）→ 禁止回退（§7.3）
    let webViewG = CountingWebViewProvider()
    rssHubRequestStub { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
        return (response, Data())
    }
    let routerG = XTimelineRouter(
        webViewProvider: webViewG,
        healthTracker: InstanceHealthTracker(),
        rssHubClientFactory: makeRSSHubClientFactory()
    )
    do {
        _ = try await routerG.fetch(request, settings: settingsThen, cursorInitialized: true)
        return "404 应抛错"
    } catch SourceError.accountUnavailable {
        let count = await webViewG.fetchCount
        if count != 0 { return "404 时不应回退 WebView" }
    } catch {
        return "404 错误类型不符: \(error)"
    }

    // 8. xWebOnly：只调用 WebView，零 RSSHub 请求（§12.4 "xWebOnly 只调用 WebView"）
    let rssHubCalls = Counter()
    do {
        rssHubRequestStub { request in
            rssHubCalls.increment()
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let webViewH = CountingWebViewProvider()
        let routerH = XTimelineRouter(
            webViewProvider: webViewH,
            healthTracker: InstanceHealthTracker(),
            rssHubClientFactory: makeRSSHubClientFactory()
        )
        let settingsWebOnly = XSourceSettings(
            policy: .xWebOnly,
            rssHubInstances: [],
            webFallbackRiskAcknowledged: false,
            sourceSetupCompleted: true
        )
        let result = try await routerH.fetch(request, settings: settingsWebOnly, cursorInitialized: true)
        if result.providerID != .xWeb { return "xWebOnly 应返回 xWeb，实际 \(result.providerID)" }
        let webCount = await webViewH.fetchCount
        if webCount != 1 { return "xWebOnly 应恰好调用一次 WebView，实际 \(webCount)" }
        if rssHubCalls.count != 0 { return "xWebOnly 不应发起任何 RSSHub 请求（\(rssHubCalls.count) 次）" }
    } catch {
        return "xWebOnly 成功路径抛错: \(error)"
    }

    // 9. RSSHub 全部失败且 X 未登录（WebView 抛 authenticationRequired）：
    //    回退错误正确传播、WebView 不循环重试、不产生任何登录弹窗（§12.4 最后一条）。
    do {
        let webViewI = CountingWebViewProvider()
        await webViewI.setResult(.failure(TimelineError.authenticationRequired))
        let routerI = XTimelineRouter(
            webViewProvider: webViewI,
            healthTracker: InstanceHealthTracker(),
            rssHubClientFactory: makeRSSHubClientFactory()
        )
        rssHubRequestStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        do {
            _ = try await routerI.fetch(request, settings: settingsThen, cursorInitialized: true)
            return "X 未登录时回退应抛 authenticationRequired"
        } catch SourceError.authenticationRequired {
            let count = await webViewI.fetchCount
            if count != 1 { return "X 未登录时 WebView 只应被调用一次，实际 \(count) 次" }
        } catch {
            return "X 未登录错误类型不符: \(error)"
        }
    }

    // 9b. 同一场景走真实 Pipeline：loginRequired=true，零通知、零事件副作用。
    //     （pipeline 与 router 均无 XSession，登录窗口只由用户显式触发——结构性保证。）
    do {
        let loginRule = MonitorRule(
            name: "Login rule",
            accountHandle: "agenttest",
            triggerMode: .keywords,
            includeKeywords: ["feature"],
            keywordMatchMode: .any,
            notificationChannels: [.macOS]
        )
        rssHubRequestStub { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let webAuth = MockTimelineProvider()
        await webAuth.setShouldThrow(.authenticationRequired)
        let (pipeAuth, histAuth) = await makeRecordedPipeline(webView: webAuth) { _ in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MockURLProtocol.self]
            return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: ["rsshub.app"])
        }
        let settingsThenAck = XSourceSettings(
            policy: .rssHubThenXWeb,
            rssHubInstances: ["https://rsshub.app"],
            webFallbackRiskAcknowledged: true,
            sourceSetupCompleted: true
        )
        let sAuth = await pipeAuth.runCheck(
            reason: .manual,
            rules: [loginRule],
            accountCursors: ["agenttest": AccountCursor(
                seenTweetIDs: ["known"], initialized: true,
                lastCheckedAt: Date(), lastSuccessfulFetchAt: Date(), lastErrorCode: nil
            )],
            sourceSettings: settingsThenAck
        )
        if sAuth.loginRequired != true { return "RSSHub 失败且 X 未登录应置 loginRequired" }
        if sAuth.eventsGenerated != 0 { return "X 未登录时不得产生通知事件" }
        let authRecords = await histAuth.loadRecords()
        if authRecords.contains(where: { $0.outcome == .matched }) {
            return "X 未登录时不得产生命中记录"
        }
    }

    // 10. redirectRejected（实例把路由 302 跳走，如公共实例）→ 自动尝试下一实例（§7.2）
    do {
        let goodFeed = rssHubFixture(now: Date())
        rssHubRequestStub { request in
            guard let host = request.url?.host else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            if host == "rsshub.app" {
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: 302, httpVersion: nil,
                    headerFields: ["Location": "https://www.google.com/404"]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, goodFeed)
        }
        let routerJ = XTimelineRouter(
            webViewProvider: CountingWebViewProvider(),
            healthTracker: InstanceHealthTracker(),
            rssHubClientFactory: makeRSSHubClientFactory(host: "rsshub.app")
        )
        let settingsTwo = XSourceSettings(
            policy: .rssHubOnly,
            rssHubInstances: ["https://rsshub.app", "https://rsshub.alt.app"],
            webFallbackRiskAcknowledged: false,
            sourceSetupCompleted: true
        )
        do {
            let result = try await routerJ.fetch(request, settings: settingsTwo, cursorInitialized: true)
            if result.providerID != .rssHub { return "redirectRejected 后应仍返回 rssHub" }
            if result.instanceHost != "rsshub.alt.app" { return "redirectRejected 应回退到下一实例，实际 host=\(result.instanceHost ?? "nil")" }
        } catch {
            return "redirectRejected 实例回退失败: \(error)"
        }
    }

    return nil
}

// 空 Feed 状态判定（§6.1、§12.4）：已初始化→suspiciousEmpty 尝试下一实例；未初始化→emptyUnverified
func checkRouterEmptyFeed() async -> String? {
    let request = TimelineRequest(accountHandle: "agenttest", includeReplies: false, includeReposts: false, maximumCount: 10)
    let emptyBody = Data("<rss version=\"2.0\"><channel><title>T</title></channel></rss>".utf8)
    let instances = ["https://a.rsshub.app", "https://b.rsshub.app"]
    let settings = XSourceSettings(
        policy: .rssHubOnly,
        rssHubInstances: instances,
        webFallbackRiskAcknowledged: false,
        sourceSetupCompleted: true
    )

    // 已初始化账号：两个实例都 2xx 空 → 尝试全部实例 → suspiciousEmpty
    let countInit = Counter()
    rssHubRequestStub { request in
        countInit.increment()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, emptyBody)
    }
    let routerInit = XTimelineRouter(
        webViewProvider: CountingWebViewProvider(),
        healthTracker: InstanceHealthTracker(),
        rssHubClientFactory: makeRSSHubClientFactory()
    )
    do {
        _ = try await routerInit.fetch(request, settings: settings, cursorInitialized: true)
        return "已初始化账号 2xx 空 Feed 应失败"
    } catch SourceError.suspiciousEmpty {
        if countInit.count != 2 { return "可疑空 Feed 应尝试全部实例，实际 \(countInit.count) 次" }
    } catch {
        return "suspiciousEmpty 错误类型不符: \(error)"
    }
    // 冷却：两实例都进入 5 分钟冷却，后续请求直接失败且不触发网络
    do {
        _ = try await routerInit.fetch(request, settings: settings, cursorInitialized: true)
        return "冷却中应失败"
    } catch {
        // 预期失败
    }
    if countInit.count != 2 { return "冷却中的实例不应被再次请求（实际 \(countInit.count) 次）" }

    // 未初始化账号：2xx 空 → emptyUnverified（独立 router，避免冷却干扰）
    let countFresh = Counter()
    rssHubRequestStub { request in
        countFresh.increment()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, emptyBody)
    }
    let routerFresh = XTimelineRouter(
        webViewProvider: CountingWebViewProvider(),
        healthTracker: InstanceHealthTracker(),
        rssHubClientFactory: makeRSSHubClientFactory()
    )
    do {
        _ = try await routerFresh.fetch(request, settings: settings, cursorInitialized: false)
        return "未初始化账号 2xx 空 Feed 应失败"
    } catch SourceError.emptyUnverified {
        if countFresh.count != 2 { return "未初始化空 Feed 应尝试全部实例，实际 \(countFresh.count) 次" }
    } catch {
        return "emptyUnverified 错误类型不符: \(error)"
    }

    return nil
}

// MARK: - TASK-10: 自定义 RSS 源规则（DESIGN-RSSHUB.md §13）

@MainActor
func checkGenericRSSFeeds() async -> String? {
    let now = Date()
    // 窗口内/外的日期必须相对 now 生成，硬编码日历日期会随时间推移失效。
    let rfc822: (Date) -> String = { date in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.string(from: date)
    }
    // 取整到整秒：RFC822 只保留秒级精度，否则 round-trip 不等。
    let recentDate = Date(timeIntervalSince1970: now.addingTimeInterval(-1 * 24 * 60 * 60).timeIntervalSince1970.rounded())
    let ancientDate = Date(timeIntervalSince1970: now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970.rounded())

    // --- 1. parseGeneric：通用条目映射 ---
    let xml = Data("""
    <rss version="2.0"><channel><title>Example News</title>
      <item>
        <title>Launch: <b>feature</b> ready</title>
        <link>https://news.example/items/1</link>
        <guid>https://news.example/items/1</guid>
        <pubDate>\(rfc822(recentDate))</pubDate>
        <author>newsroom</author>
      </item>
      <item>
        <title>No-date entry</title>
        <link>https://news.example/items/2</link>
        <guid>guid-2</guid>
      </item>
      <item>
        <title>Ancient entry</title>
        <link>https://news.example/items/3</link>
        <guid>guid-3</guid>
        <pubDate>\(rfc822(ancientDate))</pubDate>
      </item>
      <item>
        <title>X status link</title>
        <link>https://x.com/user/status/1234567890123456789</link>
      </item>
      <item>
        <title>Relative link</title>
        <link>/relative</link>
      </item>
    </channel></rss>
    """.utf8)
    let parsed: RSSParseResult
    do {
        parsed = try XRSSParser.parseGeneric(data: xml, defaultAuthor: "news.example", maximumCount: 10, now: now)
    } catch {
        return "parseGeneric 抛错: \(error)"
    }
    // 5 个条目里：relative 无 URL 被跳过；ancient(Jul 26) 与 X(2010) 超三天窗口被丢弃
    if parsed.rawItemCount != 4 { return "generic rawItemCount 应为 4，实际 \(parsed.rawItemCount)" }
    if parsed.tweets.count != 2 { return "generic 窗口内应为 2 条，实际 \(parsed.tweets.count)" }

    // 无日期条目按 now 处理，时间最新排第一
    let undated = parsed.tweets[0]
    if undated.id != "guid-2" { return "无日期条目 id 应用 guid" }
    if undated.authorHandle != "news.example" { return "无作者条目应用默认 host 作者" }
    if undated.url.absoluteString != "https://news.example/items/2" { return "无日期条目 url 应用 link" }
    if abs(undated.publishedAt!.timeIntervalSince(now)) > 60 { return "无日期条目应按 now 处理" }

    let dated = parsed.tweets[1]
    if dated.id != "https://news.example/items/1" { return "有 URL guid 条目 id 应用 guid" }
    if dated.authorHandle != "newsroom" { return "条目作者应保留 author" }
    if dated.text != "Launch: ready feature" { return "标题应清理 HTML，实际 \(dated.text)" }
    if dated.kind != .original { return "generic 条目 kind 应为 original" }
    if dated.publishedAt != recentDate { return "pubDate 应被解析" }

    // X 状态链接：id 用数值推文 ID（与 X 路径去重互通）
    let xStatusXML = Data("""
    <rss version="2.0"><channel><title>T</title>
      <item>
        <title>via x</title>
        <link>https://x.com/user/status/1234567890123456789</link>
        <pubDate>\(rfc822(recentDate))</pubDate>
      </item>
    </channel></rss>
    """.utf8)
    let xParsed: RSSParseResult
    do {
        xParsed = try XRSSParser.parseGeneric(data: xStatusXML, defaultAuthor: "x.com", maximumCount: 10, now: now)
    } catch {
        return "X 链接解析抛错: \(error)"
    }
    if xParsed.tweets.first?.id != "1234567890123456789" { return "X 链接条目 id 应用推文 ID" }

    // 截取上限 10 + 排除已见（页面构成稳定：先截取最新一页、最后排除已见）。
    // 条目日期互异（i 分钟递减），排序无平局歧义：top10 恒为 m-0..m-9。
    var manyXML = "<rss version=\"2.0\"><channel><title>Many</title>"
    for i in 0..<12 {
        let d = now.addingTimeInterval(Double(-i * 60))
        manyXML += "<item><title>Item \(i)</title><link>https://news.example/m/\(i)</link><guid>m-\(i)</guid><pubDate>\(rfc822(d))</pubDate></item>"
    }
    manyXML += "</channel></rss>"
    let capped: RSSParseResult
    do {
        capped = try XRSSParser.parseGeneric(
            data: Data(manyXML.utf8), defaultAuthor: "news.example", maximumCount: 10,
            excludedTweetIDs: ["m-0", "m-1"], now: now
        )
    } catch {
        return "cap 解析抛错: \(error)"
    }
    if capped.rawItemCount != 12 { return "cap: rawItemCount 应计全部有效条目，实际 \(capped.rawItemCount)" }
    // 最新一页固定为 m-0..m-9（截取先于排除）；排除已见的 m-0/m-1 后应剩 8 条，
    // 而不是把更旧的 m-10/m-11 当作"新条目"顶上来。
    if capped.tweets.count != 8 { return "cap: 固定页面排除 2 条后应剩 8 条，实际 \(capped.tweets.count)" }

    // 回归：肥源翻页重放——首轮基线 top10，次轮同数据 + 已见=top10 → 应为空。
    let fifteenXML = {
        var xml = "<rss version=\"2.0\"><channel><title>Fifteen</title>"
        for i in 0..<15 {
            let d = now.addingTimeInterval(Double(-i * 60))
            xml += "<item><title>F \(i)</title><link>https://news.example/f/\(i)</link><guid>f-\(i)</guid><pubDate>\(rfc822(d))</pubDate></item>"
        }
        return xml + "</channel></rss>"
    }()
    guard let first = try? XRSSParser.parseGeneric(
        data: Data(fifteenXML.utf8), defaultAuthor: "n", maximumCount: 10, excludedTweetIDs: [], now: now
    ) else { return "fifteen 首轮解析失败" }
    let seenIDs = Set(first.tweets.map(\.id))
    guard seenIDs.count == 10 else { return "首轮应基线 10 条，实际 \(seenIDs.count)" }
    guard let second = try? XRSSParser.parseGeneric(
        data: Data(fifteenXML.utf8), defaultAuthor: "n", maximumCount: 10,
        excludedTweetIDs: seenIDs, now: now
    ) else { return "fifteen 次轮解析失败" }
    if !second.tweets.isEmpty {
        return "同页全已见时应返回空（不得翻页重放历史），实际 \(second.tweets.count) 条"
    }

    // --- 2. RSSDirectFeedProvider：真实 HTTP 路径 ---
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, xml)
    }
    let direct = RSSDirectFeedProvider { url in
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: url.host.map { [$0] } ?? [])
    }
    let feedURL = URL(string: "https://news.example/rss.xml")!
    do {
        let result = try await direct.fetch(rss: feedURL, excludedIDs: [], maximumCount: 10, etag: nil)
        if result.rawItemCount != 4 { return "direct provider rawItemCount 错误" }
        if result.tweets.count != 2 { return "direct provider tweets 数错误" }
        if result.feedState != .healthy { return "direct provider feedState 应为 healthy" }
        if result.tweets.first?.authorHandle != "news.example" { return "direct provider 默认作者应为 host" }
    } catch {
        return "direct provider 抓取抛错: \(error)"
    }

    // 2b. x.com 域名直接拒绝
    do {
        _ = try await direct.fetch(rss: URL(string: "https://x.com/foo/rss.xml")!, excludedIDs: [], maximumCount: 10, etag: nil)
        return "x.com 不能作为 RSS 源"
    } catch RSSDirectFeedError.disallowedHost {
        // 预期
    } catch {
        return "x.com 拒绝错误类型不符: \(error)"
    }

    // 2c. 跨 host 重定向拒绝
    MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": "https://other.example/feed"]
        )!
        return (response, Data())
    }
    do {
        _ = try await direct.fetch(rss: feedURL, excludedIDs: [], maximumCount: 10, etag: nil)
        return "跨 host 重定向应被拒绝"
    } catch SourceError.redirectRejected {
        // 预期（§5.2）
    } catch {
        return "重定向拒绝错误类型不符: \(error)"
    }

    // --- 3. Pipeline 全链路（mock feed provider）---
    let feedRule = MonitorRule(
        name: "News watch",
        accountHandle: "新闻站",
        feedURL: "https://news.example/rss.xml",
        triggerMode: .keywords,
        includeKeywords: ["feature"],
        keywordMatchMode: .any,
        notificationChannels: [.macOS]
    )
    let key = "https://news.example/rss.xml"
    let t1 = Tweet(id: "https://news.example/items/1", authorHandle: "news.example",
                   text: "feature ready", url: URL(string: "https://news.example/items/1")!,
                   publishedAt: now, kind: .original)
    let t2 = Tweet(id: "https://news.example/items/2", authorHandle: "news.example",
                   text: "another feature post", url: URL(string: "https://news.example/items/2")!,
                   publishedAt: now, kind: .original)
    let mockFeed = MockDirectFeedProvider()
    await mockFeed.setResult(for: key, result: RSSDirectFeedResult(
        tweets: [t1], rawItemCount: 1, feedState: .healthy, eTag: nil
    ))
    let (pipe, hist) = await makeRecordedPipeline(
        webView: MockTimelineProvider(),
        factory: { _ in RSSHubHTTPClient() },
        feedProvider: mockFeed
    )

    // 3a. 首次基线：不通知、初始化 Cursor
    let sBase = await pipe.runCheck(
        reason: .manual, rules: [feedRule],
        accountCursors: [key: .empty], sourceSettings: legacyPipelineSourceSettings
    )
    let cBase = sBase.accountCursors[key]
    if cBase?.initialized != true { return "feed 首次抓取应初始化 Cursor" }
    if cBase?.seenTweetIDs != [t1.id] { return "feed 首次应保存返回 ID" }
    if sBase.eventsGenerated != 0 { return "feed 首次不应通知" }
    if sBase.error != nil { return "feed 首次不应报错: \(sBase.error!)" }

    // 3b. 新条目 → 触发 + 记录 .rssFeed
    await mockFeed.setResult(for: key, result: RSSDirectFeedResult(
        tweets: [t1, t2], rawItemCount: 2, feedState: .healthy, eTag: nil
    ))
    let sNew = await pipe.runCheck(
        reason: .manual, rules: [feedRule],
        accountCursors: [key: cBase!], sourceSettings: legacyPipelineSourceSettings
    )
    if sNew.eventsGenerated != 1 { return "feed 新条目应触发通知" }
    let records = await hist.loadRecords()
    let matched = records.first { $0.outcome == .matched }
    if matched == nil { return "feed 命中应记录 .matched" }
    if matched!.providerID != .rssFeed { return "feed 记录 providerID 应为 .rssFeed" }
    if matched!.instanceHost != "news.example" { return "feed 记录应带 host" }
    if matched!.matchedRuleNames != ["News watch"] { return "feed 记录应带规则名" }

    // 3c. 重复条目去重
    let sDup = await pipe.runCheck(
        reason: .manual, rules: [feedRule],
        accountCursors: [key: sNew.accountCursors[key]!], sourceSettings: legacyPipelineSourceSettings
    )
    if sDup.eventsGenerated != 0 { return "feed 重复条目不应再通知" }

    // 3d. 空 Feed（未初始化）→ emptyUnverified：不初始化、不推进成功时间
    await mockFeed.setResult(for: key, result: RSSDirectFeedResult(
        tweets: [], rawItemCount: 0, feedState: .healthy, eTag: nil
    ))
    let sEmpty = await pipe.runCheck(
        reason: .manual, rules: [feedRule],
        accountCursors: [key: .empty], sourceSettings: legacyPipelineSourceSettings
    )
    let cEmpty = sEmpty.accountCursors[key]
    if cEmpty?.initialized == true { return "feed 首次空 Feed 不得初始化 Cursor" }
    if cEmpty?.lastSuccessfulFetchAt != nil { return "feed 空 Feed 不得推进 lastSuccessfulFetchAt" }
    if sEmpty.error == nil || !sEmpty.isTransientError { return "feed 空 Feed 应报 transient 错误" }

    // 3e. 空 Feed（已初始化）→ suspiciousEmpty
    let sEmpty2 = await pipe.runCheck(
        reason: .manual, rules: [feedRule],
        accountCursors: [key: cBase!], sourceSettings: legacyPipelineSourceSettings
    )
    if sEmpty2.error == nil || !sEmpty2.isTransientError { return "feed 已初始化空 Feed 应报 transient 错误" }

    // 3f. notModified → 健康
    await mockFeed.setResult(for: key, result: RSSDirectFeedResult(
        tweets: [], rawItemCount: 0, feedState: .notModified, eTag: "\"v2\""
    ))
    let sNM = await pipe.runCheck(
        reason: .manual, rules: [feedRule],
        accountCursors: [key: cBase!], sourceSettings: legacyPipelineSourceSettings
    )
    if sNM.error != nil { return "feed notModified 不应报错" }
    if sNM.accountCursors[key]?.lastSuccessfulFetchAt == nil {
        return "feed notModified 应推进 lastSuccessfulFetchAt"
    }

    // 3g. 无效 URL → actionRequired；不访问 Router
    let badRule = MonitorRule(
        name: "bad", accountHandle: "x", feedURL: "not a url",
        triggerMode: .keywords, includeKeywords: ["a"], notificationChannels: [.macOS]
    )
    let sBad = await pipe.runCheck(
        reason: .manual, rules: [badRule],
        accountCursors: [:], sourceSettings: legacyPipelineSourceSettings
    )
    if sBad.actionRequired == nil { return "无效 feed URL 应产生 actionRequired" }

    // 3h. X 规则 + feed 规则共存：独立计数、各自触发
    let webX = MockTimelineProvider()
    let x1 = Tweet(id: "x-1", authorHandle: "testuser", text: "feature on x",
                   url: URL(string: "https://x.com/testuser/status/x-1")!,
                   publishedAt: now, kind: .original)
    let x2 = Tweet(id: "x-2", authorHandle: "testuser", text: "feature on x again",
                   url: URL(string: "https://x.com/testuser/status/x-2")!,
                   publishedAt: now, kind: .original)
    await webX.setTweets([x1])
    let xRule = MonitorRule(
        name: "X rule", accountHandle: "testuser",
        triggerMode: .keywords, includeKeywords: ["feature"],
        keywordMatchMode: .any, notificationChannels: [.macOS]
    )
    await mockFeed.setResult(for: key, result: RSSDirectFeedResult(
        tweets: [t1], rawItemCount: 1, feedState: .healthy, eTag: nil
    ))
    let (pipeBoth, _) = await makeRecordedPipeline(
        webView: webX,
        factory: { _ in RSSHubHTTPClient() },
        feedProvider: mockFeed
    )
    // 首次：两个源都只建立基线
    let sBoth1 = await pipeBoth.runCheck(
        reason: .manual, rules: [xRule, feedRule],
        accountCursors: ["testuser": .empty, key: .empty],
        sourceSettings: legacyPipelineSourceSettings
    )
    if sBoth1.accountsChecked != 2 { return "X 与 feed 规则应分别计数" }
    if sBoth1.eventsGenerated != 0 { return "首次共存应为基线" }
    // 第二次：两边各来一条新条目
    await webX.setTweets([x1, x2])
    await mockFeed.setResult(for: key, result: RSSDirectFeedResult(
        tweets: [t1, t2], rawItemCount: 2, feedState: .healthy, eTag: nil
    ))
    let sBoth2 = await pipeBoth.runCheck(
        reason: .manual, rules: [xRule, feedRule],
        accountCursors: sBoth1.accountCursors,
        sourceSettings: legacyPipelineSourceSettings
    )
    if sBoth2.eventsGenerated != 2 { return "X 与 feed 规则都应触发，实际 \(sBoth2.eventsGenerated)" }

    return nil
}

@MainActor
func runAllChecks() async -> [String] {
    var failures: [String] = []
    var total = 0
    func run(_ name: String, _ body: () async -> String?) async {
        total += 1
        if let msg = await body() {
            failures.append("\(name): \(msg)")
            print("❌ \(name) — \(msg)")
        } else {
            print("✅ \(name)")
        }
    }
    await run("配置 v1→v2 无损迁移", { await checkConfigMigrationV2() })
    await run("可选间隔与实例 URL 校验", { checkConfigSelectableAndInstanceValidation() })
    await run("RSS 2.0 解析与映射", { checkRSSFeedRSS2() })
    await run("Atom 解析与映射", { checkRSSFeedAtom() })
    await run("RSS 安全限制", { checkRSSFeedSafety() })
    await run("RSSHub 路由构造", { checkRSSHubRequestBuilder() })
    await run("RSSHub HTTP 与 Provider", { await checkRSSHubHTTPClientAndFallback() })
    await run("实例健康与冷却", { await checkInstanceHealthTracker() })
    await run("Router 策略与回退", { await checkRouterPolicies() })
    await run("Router 空 Feed 判定", { await checkRouterEmptyFeed() })
    await run("通用 RSS 源规则", { await checkGenericRSSFeeds() })
    await run("Cursor 语义与去重", { await checkPipelineCursorSemantics() })
    await run("调度抖动与配置门槛", { await checkSchedulerJitterAndConfig() })
    await run("账号 URL 解析", { checkAccountURLParsing() })
    await run("记录归属与展示名", { checkRecordRuleMatching() })
    await run("事件保留策略接线", { await checkEventRetentionPolicy() })
    await run("规则完备性校验", { checkMonitorRuleReadiness() })
    await run("关键词左词边界", { checkKeywordWordBoundary() })
    await run("通知投递策略接线", { await checkGatewayDeliveryPolicy() })
    await run("暂停拦截手动与唤醒", { await checkSchedulerPauseGatesManualAndWake() })
    await run("运行状态结构化分类", { checkStatusClassification() })
    await run("状态导航提示", { checkStatusNavigationHint() })
    await run("失败记录来源标注", { await checkFailureRecordProviderHint() })
    await run("冷却错误不刷屏", { await checkCooldownNoiseSuppression() })
    await run("关键词匹配", { await checkKeywordMatching() })
    await run("关键词排除与全匹配", { checkKeywordExcludeAndAll() })
    await run("Unicode 规范化", { checkUnicodeNormalization() })
    await run("推文类型过滤", { checkTweetTypeFiltering() })
    await run("首次基线不通知", { await checkFirstBaseline() })
    await run("去重（跨重启）", { await checkDedupAcrossRestart() })
    await run("调度防重入", { await checkSchedulerReentrancy() })
    await run("状态持久化", { await checkStatePersistence() })
    await run("事件历史上限", { await checkEventPruning() })
    await run("抓取与规则诊断", { await checkFetchDiagnostics() })
    await run("时间线作者过滤", { checkTimelineAuthorFiltering() })
    await run("登录态持久化恢复", { checkPersistentLoginCookieDetection() })
    await run("Telegram 错误处理", { await checkTelegramErrors() })
    await run("登录状态机", { checkLoginStateMachine() })
    await run("Mock 完整链路", { await checkMockFullChain() })
    let passed = total - failures.count
    print("    小计: \(passed)/\(total)")
    return failures
}

@main
struct XRadarVerifier {
    static func main() async {
        let failures = await runAllChecks()
        print("")
        if failures.isEmpty {
            print("SUCCESS XRadarVerifier: ALL CHECKS PASSED")
            exit(0)
        } else {
            print("FAILURE XRadarVerifier: \(failures.count) CHECK(S) FAILED")
            exit(1)
        }
    }
}
