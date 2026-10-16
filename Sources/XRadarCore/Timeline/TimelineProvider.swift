// TimelineProvider.swift
import Foundation

// Use a simple HTTP-based approach instead of WebView
// This fetches the public timeline as HTML and parses it

public protocol TimelineProvider: Sendable {
    var id: TimelineProviderID { get }
    func fetch(_ request: TimelineRequest) async throws -> TimelineFetchResult
}

public struct HTTPValidator: Codable, Equatable, Sendable {
    public let eTag: String?
    public let lastModified: String?

    public init(eTag: String? = nil, lastModified: String? = nil) {
        self.eTag = eTag
        self.lastModified = lastModified
    }

    public var isEmpty: Bool {
        self.eTag == nil && self.lastModified == nil
    }

    public static func sourceKey(provider: TimelineProviderID, identity: String) -> String {
        "\(provider.rawValue):\(identity.lowercased())"
    }
}

public struct TimelineRequest: Equatable, Sendable {
    public let accountHandle: String
    public let includeReplies: Bool
    public let includeReposts: Bool
    public let excludedTweetIDs: Set<String>
    public let earliestPublishedAt: Date?
    public let maximumCount: Int
    /// Conditional validators persisted by source identity (provider + host/feed URL).
    public let httpValidators: [String: HTTPValidator]

    public init(
        accountHandle: String,
        includeReplies: Bool,
        includeReposts: Bool = false,
        excludedTweetIDs: Set<String> = [],
        earliestPublishedAt: Date? = nil,
        maximumCount: Int,
        httpValidators: [String: HTTPValidator] = [:]
    ) {
        self.accountHandle = accountHandle
        self.includeReplies = includeReplies
        self.includeReposts = includeReposts
        self.excludedTweetIDs = excludedTweetIDs
        self.earliestPublishedAt = earliestPublishedAt
        self.maximumCount = maximumCount
        self.httpValidators = httpValidators
    }
}

// MARK: - 抓取结果（DESIGN-RSSHUB.md §3.2）

/// Provider 抓取结果。`rawItemCount` 是解析前的有效条目数，
/// 不能用"排除已见 ID 后的数量"判断 Feed 是否为空。
public struct TimelineFetchResult: Sendable {
    public let tweets: [Tweet]
    public let providerID: TimelineProviderID
    public let instanceHost: String?
    public let fallbackFromProviderID: TimelineProviderID?
    public let rawItemCount: Int
    public let feedState: FeedState
    public let httpValidator: HTTPValidator?

    public init(
        tweets: [Tweet],
        providerID: TimelineProviderID,
        instanceHost: String? = nil,
        fallbackFromProviderID: TimelineProviderID? = nil,
        rawItemCount: Int,
        feedState: FeedState,
        httpValidator: HTTPValidator? = nil
    ) {
        self.tweets = tweets
        self.providerID = providerID
        self.instanceHost = instanceHost
        self.fallbackFromProviderID = fallbackFromProviderID
        self.rawItemCount = rawItemCount
        self.feedState = feedState
        self.httpValidator = httpValidator
    }
}

public enum FeedState: Sendable, Equatable {
    case healthy
    case notModified
}

// MARK: - 错误模型（DESIGN-RSSHUB.md §7.1）

/// 与页面 DOM 无关的信源错误。RSS 错误禁止映射成 `.pageStructureChanged`。
public enum SourceError: Error, Equatable, Sendable {
    case configurationRequired
    case invalidInstanceURL
    case accountUnavailable(statusCode: Int)
    case rateLimited(provider: TimelineProviderID, retryAfter: Date?)
    case networkUnavailable(provider: TimelineProviderID)
    case requestTimeout(provider: TimelineProviderID)
    case invalidFeed
    case suspiciousEmpty
    case emptyUnverified
    case responseTooLarge
    case redirectRejected
    case httpStatus(provider: TimelineProviderID, statusCode: Int)
    case instancesCoolingDown(lastError: String?)
    case authenticationRequired(provider: TimelineProviderID)
    case userActionRequired(String)
}

extension SourceError: LocalizedError {
    /// 失败记录可提取的来源 Provider 提示（写入 FetchRecord 便于诊断）。
    public var providerHint: TimelineProviderID? {
        switch self {
        case .rateLimited(let provider, _),
             .networkUnavailable(let provider),
             .requestTimeout(let provider),
             .httpStatus(let provider, _),
             .authenticationRequired(let provider):
            return provider
        default:
            return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .configurationRequired:
            return "需要配置 RSSHub 信源"
        case .invalidInstanceURL:
            return "RSSHub 实例地址无效"
        case .accountUnavailable(let statusCode):
            return "账号不可用（HTTP \(statusCode)）"
        case .rateLimited(_, let retryAfter):
            if let retryAfter {
                return "请求受限，请在 \(retryAfter.formatted(.dateTime.hour().minute())) 后重试"
            }
            return "请求受限，请稍后重试"
        case .networkUnavailable:
            return "网络不可用，无法访问信源"
        case .requestTimeout:
            return "请求超时"
        case .invalidFeed:
            return "RSS 内容无效"
        case .suspiciousEmpty:
            return "RSS 内容异常为空"
        case .emptyUnverified:
            return "RSS 内容为空（尚未建立基线）"
        case .responseTooLarge:
            return "RSS 响应过大"
        case .redirectRejected:
            return "重定向被拒绝"
        case .httpStatus(_, let statusCode):
            return "信源返回 HTTP \(statusCode)，请检查实例权限或配置"
        case .instancesCoolingDown(let lastError):
            if let lastError, !lastError.isEmpty {
                return "RSSHub 实例正在冷却：\(lastError)"
            }
            return "RSSHub 实例正在冷却，请稍后重试"
        case .authenticationRequired:
            return "X 登录已失效，请重新登录"
        case .userActionRequired(let message):
            return "需要处理: \(message)"
        }
    }
}

// MARK: - 兼容 WebView 的既有错误（DESIGN.md §10.7）

public enum TimelineError: Error, Equatable {
    case authenticationRequired
    case userActionRequired(String)
    case rateLimited(retryAfter: Date?)
    case pageLoadTimeout
    case pageStructureChanged
    case networkUnavailable
}

extension TimelineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "X 登录已失效，请重新登录"
        case .userActionRequired(let message):
            return message
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "X 请求受限，请在 \(retryAfter.formatted(.dateTime.hour().minute())) 后重试"
            }
            return "X 请求受限，请稍后重试"
        case .pageLoadTimeout:
            return "X 页面加载超时"
        case .pageStructureChanged:
            return "X 页面没有加载出推文，可能是页面结构变化、账号不存在或触发了风控"
        case .networkUnavailable:
            return "网络不可用，无法加载 X 页面"
        }
    }
}
