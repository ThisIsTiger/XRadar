// MonitoringPipeline.swift
import Foundation

/// Protocol abstraction so the scheduler can be tested with a mock pipeline.
public protocol MonitoringPipelineType: Actor {
    func runCheck(
        reason: TriggerReason,
        rules: [MonitorRule],
        accountCursors: [String: AccountCursor],
        sourceSettings: XSourceSettings
    ) async -> PollRunSummary
}

public actor MonitoringPipeline: MonitoringPipelineType {
    private let router: XTimelineRouter
    private let ruleEngine: RuleEngine
    private let eventRepository: EventRepository
    private let notificationGateway: NotificationGateway
    private let fetchHistoryRepository: FetchHistoryRepository?
    private let feedProvider: any RSSDirectFeedProviding

    public init(
        router: XTimelineRouter,
        ruleEngine: RuleEngine,
        eventRepository: EventRepository,
        notificationGateway: NotificationGateway,
        fetchHistoryRepository: FetchHistoryRepository? = nil,
        feedProvider: (any RSSDirectFeedProviding)? = nil
    ) {
        self.router = router
        self.ruleEngine = ruleEngine
        self.eventRepository = eventRepository
        self.notificationGateway = notificationGateway
        self.fetchHistoryRepository = fetchHistoryRepository
        self.feedProvider = feedProvider ?? RSSDirectFeedProvider()
    }

    /// 本轮运行时的累计状态（§13：X 账号与自定义 RSS 源共用同一套错误处理）。
    private struct RunAccumulator {
        var totalTweetsFound = 0
        var totalEventsGenerated = 0
        var updatedCursors: [String: AccountCursor]
        var loginRequired = false
        var actionRequired: String?
        var rateLimited = false
        var configurationRequired = false
        var rateLimitedUntil: Date?
        var firstError: String?
        var isTransientError = false
    }

    /// Production entry point used by the scheduler. Loads enabled rules and the
    /// current per-account cursors, processes every account, persists the updated
    /// cursors, and returns a summary describing what happened (including whether
    /// a login / user-action / rate-limit condition was encountered).
    public func runCheck(
        reason: TriggerReason,
        rules: [MonitorRule],
        accountCursors: [String: AccountCursor],
        sourceSettings: XSourceSettings
    ) async -> PollRunSummary {
        let startTime = Date()

        // 新一轮：重置 Router 的"本轮回退"标记（§7.3）。
        await router.beginRound()

        // Only consider enabled rules. 自定义 RSS 源规则按 feedURL 分组（§13），
        // 与 X 账号规则（按 accountHandle 分组）互不混叠。
        let enabledRules = rules.filter(\.enabled)
        let rulesByAccount = Dictionary(grouping: enabledRules.filter { $0.feedURL == nil }) { $0.accountHandle }
        let feedRulesByURL = Dictionary(grouping: enabledRules.filter { $0.feedURL != nil }) { $0.feedURL! }
        var acc = RunAccumulator(updatedCursors: accountCursors)

        for (handle, accountRules) in rulesByAccount {
            await processSource(
                key: handle,
                feedURL: nil,
                rules: accountRules,
                sourceSettings: sourceSettings,
                accountCursors: accountCursors,
                accumulator: &acc
            )
        }

        for (url, feedRules) in feedRulesByURL {
            await processSource(
                key: url,
                feedURL: url,
                rules: feedRules,
                sourceSettings: sourceSettings,
                accountCursors: accountCursors,
                accumulator: &acc
            )
        }

        return PollRunSummary(
            startTime: startTime,
            endTime: Date(),
            accountsChecked: rulesByAccount.count + feedRulesByURL.count,
            tweetsFound: acc.totalTweetsFound,
            eventsGenerated: acc.totalEventsGenerated,
            loginRequired: acc.loginRequired,
            actionRequired: acc.actionRequired,
            rateLimited: acc.rateLimited,
            rateLimitedUntil: acc.rateLimitedUntil,
            error: acc.firstError,
            isTransientError: acc.isTransientError,
            configurationRequired: acc.configurationRequired,
            accountCursors: acc.updatedCursors
        )
    }

    /// 对单个信源（X 账号或 RSS 源）执行一次抓取 + 规则判定。
    private func processSource(
        key: String,
        feedURL: String?,
        rules: [MonitorRule],
        sourceSettings: XSourceSettings,
        accountCursors: [String: AccountCursor],
        accumulator: inout RunAccumulator
    ) async {
        let cursor = accountCursors[key] ?? AccountCursor(
            seenTweetIDs: [],
            initialized: false,
            lastCheckedAt: nil,
            lastSuccessfulFetchAt: nil,
            lastErrorCode: nil
        )

        do {
            let (newCursor, events, fetchedCount) = try await processAccount(
                key,
                feedURL: feedURL,
                rules: rules,
                cursor: cursor,
                sourceSettings: sourceSettings
            )
            accumulator.updatedCursors[key] = newCursor
            accumulator.totalTweetsFound += fetchedCount
            accumulator.totalEventsGenerated += events.count

            if !events.isEmpty {
                await eventRepository.appendEvents(events)
            }
        } catch {
            await recordFailure(key: key, cursor: cursor, error: error, accumulator: &accumulator)
        }
    }

    /// 记录一次抓取失败并更新累计状态（§7.1 错误分类，X 与 RSS 源共用）。
    private func recordFailure(
        key: String,
        cursor: AccountCursor,
        error: Error,
        accumulator: inout RunAccumulator
    ) async {
        if let fetchHistoryRepository = self.fetchHistoryRepository {
            // 冷却噪音抑制：同一信源连续多轮抛出相同/同根因的错误时，只在
            // 首轮写入诊断行。"冷却包装"文案（"…正在冷却：<根因>"）包含上一
            // 轮根因文案，同样视为重复。状态汇总仍每轮如实上报。
            let description = error.localizedDescription
            let isRepeatOfLastError: Bool
            if let lastCode = cursor.lastErrorCode {
                isRepeatOfLastError = lastCode == description || description.contains(lastCode)
            } else {
                isRepeatOfLastError = false
            }
            if !isRepeatOfLastError {
                // 失败记录尽量标注来源 Provider（诊断页可区分 RSSHub/X/自定义源）。
                let providerHint: TimelineProviderID?
                if let sourceError = error as? SourceError {
                    providerHint = sourceError.providerHint
                } else if error is RSSDirectFeedError {
                    providerHint = .rssFeed
                } else if let timelineError = error as? TimelineError {
                    providerHint = timelineError == .authenticationRequired ? .xWeb : nil
                } else {
                    providerHint = nil
                }
                await fetchHistoryRepository.appendRecords([
                    FetchRecord(
                        accountHandle: key,
                        message: error.localizedDescription,
                        providerID: providerHint
                    )
                ])
            }
        }
        // Mark the account cursor with the failure so it can recover next time.
        var failed = cursor
        failed.lastCheckedAt = Date()   // §6.2：完成一次尝试后更新
        failed.lastErrorCode = error.localizedDescription
        accumulator.updatedCursors[key] = failed

        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationRequired:
                accumulator.loginRequired = true
            case .userActionRequired(let message):
                accumulator.actionRequired = message
            case .rateLimited(_, let retryAfter):
                accumulator.rateLimited = true
                // §8.3：记录最早可重试时间（Retry-After），供 Scheduler 使用。
                if let retryAfter {
                    accumulator.rateLimitedUntil = accumulator.rateLimitedUntil.map { min($0, retryAfter) } ?? retryAfter
                }
            case .configurationRequired:
                accumulator.configurationRequired = true
                if accumulator.firstError == nil { accumulator.firstError = sourceError.localizedDescription }
            case .requestTimeout, .networkUnavailable, .invalidFeed,
                 .suspiciousEmpty, .emptyUnverified, .responseTooLarge,
                 .redirectRejected, .instancesCoolingDown:
                accumulator.isTransientError = true
                if accumulator.firstError == nil { accumulator.firstError = sourceError.localizedDescription }
            case .invalidInstanceURL, .accountUnavailable, .httpStatus:
                if accumulator.firstError == nil { accumulator.firstError = sourceError.localizedDescription }
            }
        } else if let timelineError = error as? TimelineError {
            switch timelineError {
            case .authenticationRequired:
                accumulator.loginRequired = true
            case .userActionRequired(let message):
                accumulator.actionRequired = message
            case .rateLimited:
                accumulator.rateLimited = true
            case .pageLoadTimeout, .pageStructureChanged, .networkUnavailable:
                accumulator.isTransientError = true
                if accumulator.firstError == nil { accumulator.firstError = timelineError.localizedDescription }
            }
        } else if let feedError = error as? RSSDirectFeedError {
            if accumulator.firstError == nil { accumulator.firstError = feedError.localizedDescription }
        } else if accumulator.firstError == nil {
            accumulator.firstError = error.localizedDescription
        }
    }

    private func processAccount(
        _ handle: String,
        feedURL: String?,
        rules: [MonitorRule],
        cursor: AccountCursor,
        sourceSettings: XSourceSettings
    ) async throws -> (AccountCursor, [NotificationEvent], Int) {
        // Determine if we need replies (any rule opted in).
        let includeReplies = rules.contains { $0.includeReplies }
        let includeReposts = rules.contains { $0.includeReposts }
        let earliestPublishedAt = Date().addingTimeInterval(-3 * 24 * 60 * 60)

        // Compute the seen-ID set once to avoid repeated O(n) Set construction.
        let seenIDs = cursor.seenTweetIDsSet

        let result: TimelineFetchResult
        if let feedURL {
            // §13：自定义 RSS 源。不经过 Router / 策略，直接抓取该 URL；
            // feedURL 为空（未建立基线）时的空 Feed 语义与 Router 一致。
            guard let url = URL(string: feedURL), RSSDirectFeedProvider.isValidFeedURL(url) else {
                throw SourceError.userActionRequired("RSS 源地址无效：\(feedURL)")
            }
            let feedValidatorKey = HTTPValidator.sourceKey(provider: .rssFeed, identity: feedURL)
            let feedResult = try await feedProvider.fetch(
                rss: url,
                excludedIDs: seenIDs,
                maximumCount: 10,
                etag: cursor.httpValidators[feedValidatorKey]?.eTag
            )
            if feedResult.feedState != .notModified, feedResult.rawItemCount == 0 {
                throw cursor.initialized ? SourceError.suspiciousEmpty : SourceError.emptyUnverified
            }
            result = TimelineFetchResult(
                tweets: feedResult.tweets,
                providerID: .rssFeed,
                instanceHost: url.host,
                rawItemCount: feedResult.rawItemCount,
                feedState: feedResult.feedState,
                httpValidator: HTTPValidator(eTag: feedResult.eTag, lastModified: nil)
            )
        } else {
            let request = TimelineRequest(
                accountHandle: handle,
                includeReplies: includeReplies,
                includeReposts: includeReposts,
                excludedTweetIDs: seenIDs,
                earliestPublishedAt: earliestPublishedAt,
                maximumCount: 10,
                httpValidators: cursor.httpValidators
            )

            // 通过 Router 按策略抓取（§3.3）：rssHubOnly 下绝不会访问 X。
            result = try await router.fetch(
                request,
                settings: sourceSettings,
                cursorInitialized: cursor.initialized
            )
        }

        // §5.5/§6.2：三天窗口内的条目参与规则判断；窗口外的归为 historical。
        let inWindowTweets = result.tweets.filter {
            guard let publishedAt = $0.publishedAt else { return false }
            return publishedAt >= earliestPublishedAt
        }
        let staleTweets = result.tweets.filter {
            guard let publishedAt = $0.publishedAt else { return false }
            return publishedAt < earliestPublishedAt
        }
        let fetchedCount = inWindowTweets.count

        var newCursor = cursor
        var events: [NotificationEvent] = []
        var fetchRecords: [FetchRecord] = []
        let fetchedAt = Date()

        // §5.2：保存本轮条件请求 validator，供下轮 If-None-Match / If-Modified-Since。
        // RSSHub 按实例 host 键控（与 Provider 侧查找一致）；feed 按源 URL 原文键控。
        if let validator = result.httpValidator, !validator.isEmpty {
            if result.providerID == .rssFeed, let feedURL {
                newCursor.httpValidators[
                    HTTPValidator.sourceKey(provider: .rssFeed, identity: feedURL)
                ] = validator
            } else if let host = result.instanceHost {
                newCursor.httpValidators[
                    HTTPValidator.sourceKey(provider: result.providerID, identity: host)
                ] = validator
            }
        }

        if fetchedCount == 0 {
            fetchRecords.append(
                FetchRecord(
                    accountHandle: handle,
                    fetchedAt: fetchedAt,
                    outcome: .noNewTweets,
                    message: "未发现新推文",
                    providerID: result.providerID,
                    instanceHost: result.instanceHost,
                    fallbackFromProviderID: result.fallbackFromProviderID
                )
            )
        }

        if !cursor.initialized {
            // First run - establish baseline only; never notify historical tweets.
            // §6.2：保存三天窗口内的 ID；即使只有窗口外的旧条目，也建立空基线。
            for tweet in inWindowTweets {
                newCursor.addTweetID(tweet.id)
                fetchRecords.append(
                    FetchRecord(
                        tweet: tweet,
                        accountHandle: handle,
                        fetchedAt: fetchedAt,
                        outcome: .baseline,
                        providerID: result.providerID,
                        instanceHost: result.instanceHost,
                        fallbackFromProviderID: result.fallbackFromProviderID
                    )
                )
            }
            newCursor.initialized = true
        } else {
            // Filter new tweets by seen IDs (dedup across restarts and providers).
            let newTweets = inWindowTweets.filter { !seenIDs.contains($0.id) }
            let previouslySeenTweets = inWindowTweets.filter { seenIDs.contains($0.id) }

            fetchRecords.append(contentsOf: previouslySeenTweets.map {
                FetchRecord(
                    tweet: $0,
                    accountHandle: handle,
                    fetchedAt: fetchedAt,
                    outcome: .previouslySeen,
                    providerID: result.providerID,
                    instanceHost: result.instanceHost,
                    fallbackFromProviderID: result.fallbackFromProviderID
                )
            })

            for tweet in newTweets {
                newCursor.addTweetID(tweet.id)

                let matches = await ruleEngine.evaluate(tweet: tweet, against: rules)
                guard let event = ruleEngine.aggregateMatches(tweet: tweet, matches: matches, allRules: rules) else {
                    fetchRecords.append(
                        FetchRecord(
                            tweet: tweet,
                            accountHandle: handle,
                            fetchedAt: fetchedAt,
                            outcome: .notMatched,
                            providerID: result.providerID,
                            instanceHost: result.instanceHost,
                            fallbackFromProviderID: result.fallbackFromProviderID
                        )
                    )
                    continue
                }

                let matchedRules = rules.filter { rule in
                    matches.contains { $0.ruleID == rule.id }
                }
                fetchRecords.append(
                    FetchRecord(
                        tweet: tweet,
                        accountHandle: handle,
                        fetchedAt: fetchedAt,
                        outcome: .matched,
                        matchedRuleNames: matchedRules.map(\.name),
                        matchedKeywords: Array(Set(matches.flatMap(\.matchedKeywords))).sorted(),
                        providerID: result.providerID,
                        instanceHost: result.instanceHost,
                        fallbackFromProviderID: result.fallbackFromProviderID
                    )
                )

                // Determine channels from matched rules.
                var allChannels: Set<NotificationChannelID> = []
                for match in matches {
                    if let rule = rules.first(where: { $0.id == match.ruleID }) {
                        allChannels.formUnion(rule.notificationChannels)
                    }
                }

                let results = await notificationGateway.deliver(
                    event: event,
                    through: allChannels
                )

                var updatedEvent = event
                updatedEvent.channelResults = results
                events.append(updatedEvent)
            }

            // §6.2：Provider 仍返回窗口外未见 ID → 只记历史、加入 seen，禁止通知。
            for tweet in staleTweets where !seenIDs.contains(tweet.id) {
                newCursor.addTweetID(tweet.id)
                fetchRecords.append(
                    FetchRecord(
                        tweet: tweet,
                        accountHandle: handle,
                        fetchedAt: fetchedAt,
                        outcome: .historical,
                        providerID: result.providerID,
                        instanceHost: result.instanceHost,
                        fallbackFromProviderID: result.fallbackFromProviderID
                    )
                )
            }
        }

        newCursor.lastCheckedAt = Date()
        newCursor.lastSuccessfulFetchAt = Date()
        newCursor.lastErrorCode = nil
        if let fetchHistoryRepository = self.fetchHistoryRepository {
            await fetchHistoryRepository.appendRecords(fetchRecords)
        }

        return (newCursor, events, fetchedCount)
    }
}

public struct PollRunSummary: Sendable {
    public let startTime: Date
    public let endTime: Date
    public let accountsChecked: Int
    public let tweetsFound: Int
    public let eventsGenerated: Int
    public let loginRequired: Bool
    public let actionRequired: String?
    public let rateLimited: Bool
    /// 最早可重试时间（§8.3）：RSSHub 429 Retry-After 的最早值；nil 表示沿用默认。
    public let rateLimitedUntil: Date?
    public let error: String?
    /// True when the error is transient (page structure, timeout, etc.)
    public let isTransientError: Bool
    /// True when 配置缺失/未完成（§8.3）：Scheduler 显示"需要配置信源"且不退避。
    public let configurationRequired: Bool
    public let accountCursors: [String: AccountCursor]

    public init(
        startTime: Date,
        endTime: Date,
        accountsChecked: Int,
        tweetsFound: Int,
        eventsGenerated: Int,
        loginRequired: Bool,
        actionRequired: String?,
        rateLimited: Bool,
        rateLimitedUntil: Date? = nil,
        error: String?,
        isTransientError: Bool,
        configurationRequired: Bool = false,
        accountCursors: [String: AccountCursor]
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.accountsChecked = accountsChecked
        self.tweetsFound = tweetsFound
        self.eventsGenerated = eventsGenerated
        self.loginRequired = loginRequired
        self.actionRequired = actionRequired
        self.rateLimited = rateLimited
        self.rateLimitedUntil = rateLimitedUntil
        self.error = error
        self.isTransientError = isTransientError
        self.configurationRequired = configurationRequired
        self.accountCursors = accountCursors
    }

    public var duration: TimeInterval {
        endTime.timeIntervalSince(startTime)
    }
}
