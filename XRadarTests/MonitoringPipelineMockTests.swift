// MonitoringPipelineMockTests.swift
//
// End-to-end tests of `MonitoringPipeline` using mocks — no real X login,
// WebKit, or notification delivery required. These verify the core product
// guarantees: first-baseline suppression, keyword matching, dedup across a
// simulated restart, and correct propagation of login / action / rate-limit
// conditions surfaced by the session or timeline provider.
import Foundation
import WebKit
import XCTest
@testable import XRadarCore

@MainActor
final class MonitoringPipelineMockTests: XCTestCase {
    var pipeline: MonitoringPipeline!
    var mockTimeline: MockTimelineProvider!
    var mockSession: MockSession!
    var mockMacOSNotifier: MockNotificationChannel!
    var mockTelegramNotifier: MockNotificationChannel!

    override func setUp() async throws {
        mockTimeline = MockTimelineProvider()
        mockSession = MockSession()
        mockMacOSNotifier = MockNotificationChannel(id: .macOS)
        mockTelegramNotifier = MockNotificationChannel(id: .telegram)

        let notificationGateway = NotificationGateway(
            channels: [mockMacOSNotifier as any NotificationChannel, mockTelegramNotifier as any NotificationChannel]
        )

        let router = XTimelineRouter(
            webViewProvider: mockTimeline,
            healthTracker: InstanceHealthTracker()
        )
        pipeline = MonitoringPipeline(
            router: router,
            ruleEngine: RuleEngine(),
            eventRepository: EventRepository(),
            notificationGateway: notificationGateway
        )
    }

    /// 这些测试走 WebView 分支：policy .xWebOnly + 直接使用 Mock WebView。
    let sourceSettings = XSourceSettings(
        policy: .xWebOnly,
        rssHubInstances: [],
        webFallbackRiskAcknowledged: false,
        sourceSetupCompleted: true
    )

    // MARK: - First baseline

    func testFirstBaselineNoNotification() async throws {
        // DESIGN.md 13.1: the first fetch establishes a baseline and must NOT
        // notify historical tweets.
        let baselineRule = MonitorRule(
            name: "Baseline Test",
            accountHandle: "testuser",
            triggerMode: .allNewTweets,
            notificationChannels: [.macOS]
        )

        let cursor = AccountCursor.empty
        let result = await pipeline.runCheck(
            reason: .scheduled,
            rules: [baselineRule],
            accountCursors: ["testuser": cursor],
            sourceSettings: sourceSettings
        )

        let macOSevents = await mockMacOSNotifier.sentEvents
        XCTAssertEqual(macOSevents.count, 0, "First baseline should NOT notify")
        XCTAssertEqual(result.eventsGenerated, 0)
    }

    // MARK: - Keyword matching

    func testKeywordMatching() async throws {
        let keywordRule = MonitorRule(
            name: "Keyword Test",
            accountHandle: "testuser",
            triggerMode: .keywords,
            includeKeywords: ["feature", "shipped"],
            keywordMatchMode: .any,
            notificationChannels: [.macOS]
        )

        // Initialized cursor (already past baseline) so new tweets are evaluated.
        let cursor = AccountCursor(
            seenTweetIDs: ["old1"],
            initialized: true,
            lastCheckedAt: Date(),
            lastSuccessfulFetchAt: Date(),
            lastErrorCode: nil
        )

        _ = await pipeline.runCheck(
            reason: .scheduled,
            rules: [keywordRule],
            accountCursors: ["testuser": cursor],
            sourceSettings: sourceSettings
        )

        let macOSevents = await mockMacOSNotifier.sentEvents
        XCTAssertGreaterThan(macOSevents.count, 0, "Should notify on keyword match")
        XCTAssertTrue(macOSevents.first?.body.contains("feature") ?? false)
    }

    // MARK: - Dedup across restart

    func testDedupAcrossRestart() async throws {
        let rule = MonitorRule(
            name: "Dedup Test",
            accountHandle: "testuser",
            triggerMode: .keywords,
            includeKeywords: ["feature"],
            keywordMatchMode: .any,
            notificationChannels: [.macOS]
        )

        // Run 1: baseline — no notification, cursor is initialized with both IDs.
        let s1 = await pipeline.runCheck(
            reason: .scheduled,
            rules: [rule],
            accountCursors: ["testuser": .empty],
            sourceSettings: sourceSettings
        )
        XCTAssertEqual(s1.eventsGenerated, 0)
        let c1 = s1.accountCursors["testuser"]!
        XCTAssertTrue(c1.initialized)
        XCTAssertEqual(Set(c1.seenTweetIDs), Set(["1234567890", "1234567891"]))

        // Run 2: simulate an app restart with the persisted cursor and the SAME
        // tweets — already-seen tweets must not be re-notified.
        let s2 = await pipeline.runCheck(
            reason: .scheduled,
            rules: [rule],
            accountCursors: ["testuser": c1],
            sourceSettings: sourceSettings
        )
        XCTAssertEqual(s2.eventsGenerated, 0, "Seen tweets must not be re-notified after restart")

        // Run 3: a brand-new matching tweet arrives.
        await mockTimeline.setTweets(
            MockTimelineProvider.defaultTweets + [
                Tweet(
                    id: "999",
                    authorHandle: "testuser",
                    text: "feature launch now",
                    url: URL(string: "https://x.com/testuser/status/999")!,
                    publishedAt: Date().addingTimeInterval(60),
                    kind: .original
                )
            ]
        )
        let s3 = await pipeline.runCheck(
            reason: .scheduled,
            rules: [rule],
            accountCursors: ["testuser": c1],
            sourceSettings: sourceSettings
        )
        XCTAssertEqual(s3.eventsGenerated, 1, "A new tweet should be notified exactly once")
    }

    // MARK: - Login / action / rate-limit propagation

    func testLoginRequiredSuppressesNotifications() async throws {
        // 登录失效由 WebView Provider 抛出 authenticationRequired 表达（§3.3、
        // §12.4）：Router 不做自动登录弹窗，Pipeline 标记 loginRequired。
        await mockTimeline.setShouldThrow(.authenticationRequired)
        let rule = MonitorRule(
            name: "R",
            accountHandle: "testuser",
            triggerMode: .allNewTweets,
            notificationChannels: [.macOS]
        )

        let summary = await pipeline.runCheck(
            reason: .scheduled,
            rules: [rule],
            accountCursors: ["testuser": .empty],
            sourceSettings: sourceSettings
        )

        XCTAssertTrue(summary.loginRequired)
        XCTAssertEqual(summary.eventsGenerated, 0)
        let macOSevents = await mockMacOSNotifier.sentEvents
        XCTAssertEqual(macOSevents.count, 0, "Login-required must suppress notifications")
    }

    func testActionRequiredReported() async throws {
        await mockTimeline.setShouldThrow(.userActionRequired("请完成人机验证"))
        let rule = MonitorRule(
            name: "R",
            accountHandle: "testuser",
            triggerMode: .allNewTweets,
            notificationChannels: [.macOS]
        )

        let summary = await pipeline.runCheck(
            reason: .scheduled,
            rules: [rule],
            accountCursors: ["testuser": .empty],
            sourceSettings: sourceSettings
        )

        XCTAssertEqual(summary.actionRequired, "请完成人机验证")
    }

    func testRateLimitedReportedAndRecovers() async throws {
        await mockTimeline.setShouldThrow(.rateLimited(retryAfter: nil))
        let rule = MonitorRule(
            name: "R",
            accountHandle: "testuser",
            triggerMode: .allNewTweets,
            notificationChannels: [.macOS]
        )

        let summary = await pipeline.runCheck(
            reason: .scheduled,
            rules: [rule],
            accountCursors: ["testuser": .empty],
            sourceSettings: sourceSettings
        )

        XCTAssertTrue(summary.rateLimited)
        XCTAssertEqual(summary.eventsGenerated, 0)

        // Recovery: the next run (session fine, timeline fine) proceeds normally.
        await mockTimeline.setShouldThrow(nil)
        let recovered = await pipeline.runCheck(
            reason: .scheduled,
            rules: [rule],
            accountCursors: ["testuser": .empty],
            sourceSettings: sourceSettings
        )
        XCTAssertFalse(recovered.rateLimited)
        XCTAssertFalse(recovered.loginRequired)
    }

    // MARK: - TASK-10: 自定义 RSS 源规则（DESIGN-RSSHUB.md §13）

    func testFeedRuleBaselineThenNotifyAndDedup() async throws {
        let feedProvider = MockDirectFeedProvider()
        let feedPipeline = MonitoringPipeline(
            router: XTimelineRouter(
                webViewProvider: mockTimeline,
                healthTracker: InstanceHealthTracker()
            ),
            ruleEngine: RuleEngine(),
            eventRepository: EventRepository(),
            notificationGateway: NotificationGateway(
                channels: [mockMacOSNotifier as any NotificationChannel, mockTelegramNotifier as any NotificationChannel]
            ),
            feedProvider: feedProvider
        )

        let rule = MonitorRule(
            name: "News watch",
            accountHandle: "新闻站",
            feedURL: "https://news.example/rss.xml",
            triggerMode: .keywords,
            includeKeywords: ["feature"],
            keywordMatchMode: .any,
            notificationChannels: [.macOS]
        )
        let key = "https://news.example/rss.xml"
        let now = Date()
        let t1 = Tweet(id: "https://news.example/items/1", authorHandle: "news.example",
                       text: "feature ready", url: URL(string: "https://news.example/items/1")!,
                       publishedAt: now, kind: .original)
        let t2 = Tweet(id: "https://news.example/items/2", authorHandle: "news.example",
                       text: "another feature post", url: URL(string: "https://news.example/items/2")!,
                       publishedAt: now, kind: .original)
        await feedProvider.setResult(for: key, result: RSSDirectFeedResult(
            tweets: [t1], rawItemCount: 1, feedState: .healthy, eTag: nil
        ))

        // 首次基线：不通知、初始化 Cursor
        let s1 = await feedPipeline.runCheck(
            reason: .scheduled, rules: [rule],
            accountCursors: [key: .empty], sourceSettings: sourceSettings
        )
        XCTAssertEqual(s1.eventsGenerated, 0)
        let c1 = try XCTUnwrap(s1.accountCursors[key])
        XCTAssertTrue(c1.initialized)
        XCTAssertEqual(c1.seenTweetIDs, [t1.id])

        // 新条目 → 通知（作者归属不参与 feed 规则匹配）
        await feedProvider.setResult(for: key, result: RSSDirectFeedResult(
            tweets: [t1, t2], rawItemCount: 2, feedState: .healthy, eTag: nil
        ))
        let s2 = await feedPipeline.runCheck(
            reason: .scheduled, rules: [rule],
            accountCursors: [key: c1], sourceSettings: sourceSettings
        )
        XCTAssertEqual(s2.eventsGenerated, 1)
        let sent = await mockMacOSNotifier.sentEvents
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.tweetID, t2.id)

        // 重复条目 → 去重
        let c2 = try XCTUnwrap(s2.accountCursors[key])
        let s3 = await feedPipeline.runCheck(
            reason: .scheduled, rules: [rule],
            accountCursors: [key: c2], sourceSettings: sourceSettings
        )
        XCTAssertEqual(s3.eventsGenerated, 0)
    }

    func testFeedRuleEmptyFeedSemantics() async throws {
        let feedProvider = MockDirectFeedProvider()
        let feedPipeline = MonitoringPipeline(
            router: XTimelineRouter(
                webViewProvider: mockTimeline,
                healthTracker: InstanceHealthTracker()
            ),
            ruleEngine: RuleEngine(),
            eventRepository: EventRepository(),
            notificationGateway: NotificationGateway(
                channels: [mockMacOSNotifier as any NotificationChannel, mockTelegramNotifier as any NotificationChannel]
            ),
            feedProvider: feedProvider
        )
        let rule = MonitorRule(
            name: "Empty feed", accountHandle: "news", feedURL: "https://news.example/rss.xml",
            triggerMode: .keywords, includeKeywords: ["a"], notificationChannels: [.macOS]
        )
        let key = "https://news.example/rss.xml"
        await feedProvider.setResult(for: key, result: RSSDirectFeedResult(
            tweets: [], rawItemCount: 0, feedState: .healthy, eTag: nil
        ))

        // 未初始化：emptyUnverified，不得初始化 Cursor
        let s1 = await feedPipeline.runCheck(
            reason: .scheduled, rules: [rule],
            accountCursors: [key: .empty], sourceSettings: sourceSettings
        )
        let c1 = try XCTUnwrap(s1.accountCursors[key])
        XCTAssertFalse(c1.initialized)
        XCTAssertNil(c1.lastSuccessfulFetchAt)
        XCTAssertNotNil(s1.error)
        XCTAssertTrue(s1.isTransientError)

        // 无效 URL → actionRequired
        let bad = MonitorRule(
            name: "bad", accountHandle: "x", feedURL: "not a url",
            triggerMode: .keywords, includeKeywords: ["a"], notificationChannels: [.macOS]
        )
        let s2 = await feedPipeline.runCheck(
            reason: .scheduled, rules: [bad],
            accountCursors: [:], sourceSettings: sourceSettings
        )
        XCTAssertNotNil(s2.actionRequired)
    }
}

// MARK: - Mocks

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

    func setTweets(_ tweets: [Tweet]) async {
        tweetsToReturn = tweets
    }

    func setShouldThrow(_ error: TimelineError?) async {
        shouldThrow = error
    }

    func fetch(_ request: TimelineRequest) async throws -> TimelineFetchResult {
        if let error = shouldThrow {
            throw error
        }
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

    init(id: NotificationChannelID) {
        self.id = id
    }

    func send(_ event: NotificationEvent) async -> DeliveryResult {
        if shouldFail { return .failure("Mock failure") }
        sentEvents.append(event)
        return .success
    }

    func sendTest() async -> DeliveryResult {
        return shouldFail ? .failure("Test failed") : .success
    }
}

// TASK-10: 自定义 RSS 源抓取 Mock（DESIGN-RSSHUB.md §13.3）
actor MockDirectFeedProvider: RSSDirectFeedProviding {
    var results: [String: RSSDirectFeedResult] = [:]

    func setResult(for url: String, result: RSSDirectFeedResult) async {
        results[url] = result
    }

    func fetch(
        rss url: URL,
        excludedIDs: Set<String>,
        maximumCount: Int,
        etag: String?
    ) async throws -> RSSDirectFeedResult {
        if let result = results[url.absoluteString] { return result }
        return RSSDirectFeedResult(tweets: [], rawItemCount: 0, feedState: .healthy, eTag: nil)
    }
}
