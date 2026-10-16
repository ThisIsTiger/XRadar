import Foundation

public struct FetchRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let tweetID: String?
    public let accountHandle: String
    public let text: String
    public let tweetURL: URL?
    public let publishedAt: Date?
    public let tweetKind: TweetKind?
    public let fetchedAt: Date
    public let outcome: FetchOutcome
    public let matchedRuleNames: [String]
    public let matchedKeywords: [String]
    /// 来源 Provider（DESIGN-RSSHUB.md §10.3，wrapper schema 4）。旧记录解码为 nil。
    public let providerID: TimelineProviderID?
    public let instanceHost: String?
    public let fallbackFromProviderID: TimelineProviderID?

    public init(
        id: UUID = UUID(),
        tweet: Tweet,
        accountHandle: String,
        fetchedAt: Date = Date(),
        outcome: FetchOutcome,
        matchedRuleNames: [String] = [],
        matchedKeywords: [String] = [],
        providerID: TimelineProviderID? = nil,
        instanceHost: String? = nil,
        fallbackFromProviderID: TimelineProviderID? = nil
    ) {
        self.id = id
        self.tweetID = tweet.id
        self.accountHandle = accountHandle
        self.text = tweet.text
        self.tweetURL = tweet.url
        self.publishedAt = tweet.publishedAt
        self.tweetKind = tweet.kind
        self.fetchedAt = fetchedAt
        self.outcome = outcome
        self.matchedRuleNames = matchedRuleNames
        self.matchedKeywords = matchedKeywords
        self.providerID = providerID
        self.instanceHost = instanceHost
        self.fallbackFromProviderID = fallbackFromProviderID
    }

    public init(
        id: UUID = UUID(),
        accountHandle: String,
        fetchedAt: Date = Date(),
        outcome: FetchOutcome = .fetchFailed,
        message: String,
        providerID: TimelineProviderID? = nil,
        instanceHost: String? = nil,
        fallbackFromProviderID: TimelineProviderID? = nil
    ) {
        self.id = id
        self.tweetID = nil
        self.accountHandle = accountHandle
        self.text = message
        self.tweetURL = nil
        self.publishedAt = nil
        self.tweetKind = nil
        self.fetchedAt = fetchedAt
        self.outcome = outcome
        self.matchedRuleNames = []
        self.matchedKeywords = []
        self.providerID = providerID
        self.instanceHost = instanceHost
        self.fallbackFromProviderID = fallbackFromProviderID
    }
}

public enum FetchOutcome: String, Codable, CaseIterable, Sendable {
    case baseline
    case historical
    case previouslySeen
    case notMatched
    case matched
    case fetchFailed
    case noNewTweets

    public var displayName: String {
        switch self {
        case .baseline:
            return "首次基线"
        case .historical:
            return "历史补录"
        case .previouslySeen:
            return "已处理"
        case .notMatched:
            return "未命中规则"
        case .matched:
            return "已命中"
        case .fetchFailed:
            return "抓取失败"
        case .noNewTweets:
            return "暂无新推文"
        }
    }
}

// MARK: - 规则归属与展示名（feed 记录的 accountHandle 是源 URL 原文）

/// URL 形态 handle 的展示名（host 化），供列表/下拉共用。
public enum FetchRecordDisplay {
    public static func name(for accountHandle: String) -> String {
        if let url = URL(string: accountHandle), let host = url.host, !host.isEmpty {
            return host
        }
        return accountHandle
    }
}

extension FetchRecord {
    /// 该记录是否属于给定规则：feed 规则按源 URL 匹配，X 账号规则按 handle。
    public func belongsTo(rule: MonitorRule) -> Bool {
        let key = rule.feedURL ?? rule.accountHandle
        return accountHandle.lowercased() == key.lowercased()
    }

    /// 列表展示用名称：URL 形态的 handle 显示为 host，其余原样返回。
    public var accountDisplayName: String {
        FetchRecordDisplay.name(for: accountHandle)
    }
}
