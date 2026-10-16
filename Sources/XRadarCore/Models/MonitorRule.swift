// MonitorRule.swift
import Foundation

public struct MonitorRule: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    /// X 规则：账号 handle；RSS 源规则：显示名称（如站点名/域名）。
    public var accountHandle: String
    /// nil = X 账号规则；非 nil = 自定义 RSS 源规则，值为 feed 的绝对 URL。
    public var feedURL: String?
    public var enabled: Bool
    public var triggerMode: TriggerMode
    public var includeKeywords: [String]
    public var excludeKeywords: [String]
    public var keywordMatchMode: KeywordMatchMode
    public var caseSensitive: Bool
    public var includeReplies: Bool
    public var includeReposts: Bool
    public var notificationChannels: Set<NotificationChannelID>
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        accountHandle: String,
        feedURL: String? = nil,
        enabled: Bool = true,
        triggerMode: TriggerMode = .keywords,
        includeKeywords: [String] = [],
        excludeKeywords: [String] = [],
        keywordMatchMode: KeywordMatchMode = .any,
        caseSensitive: Bool = false,
        includeReplies: Bool = false,
        includeReposts: Bool = false,
        notificationChannels: Set<NotificationChannelID> = [.macOS],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.accountHandle = accountHandle
        self.feedURL = feedURL
        self.enabled = enabled
        self.triggerMode = triggerMode
        self.includeKeywords = includeKeywords
        self.excludeKeywords = excludeKeywords
        self.keywordMatchMode = keywordMatchMode
        self.caseSensitive = caseSensitive
        self.includeReplies = includeReplies
        self.includeReposts = includeReposts
        self.notificationChannels = notificationChannels
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum TriggerMode: String, Codable, Sendable, CaseIterable {
    case allNewTweets = "all"
    case keywords = "keywords"
    public var displayName: String {
        switch self {
        case .allNewTweets:
            return "所有新推文"
        case .keywords:
            return "关键词触发"
        }
    }
}

public enum KeywordMatchMode: String, Codable, Sendable, CaseIterable {
    case any
    case all

    public var displayName: String {
        switch self {
        case .any:
            return "任意关键词"
        case .all:
            return "全部关键词"
        }
    }
}

public enum NotificationChannelID: String, Codable, Hashable, Sendable, CaseIterable {
    case macOS
    case telegram

    public var displayName: String {
        switch self {
        case .macOS:
            return "macOS 通知"
        case .telegram:
            return "Telegram Bot"
        }
    }
}

// MARK: - 完备性校验（编辑器保存门槛；feed 规则同时校验 URL 合法性）

public extension MonitorRule {
    /// 规则是否具备可保存的最小配置：
    /// - X 规则：handle 非空；
    /// - feed 规则：源 URL 必须是合法 http(s) 且非 X 域名；
    /// - 关键词模式必须至少有一个正向关键词（空关键词规则永不命中，禁止静默保存）。
    var isConfigured: Bool {
        if let feedURL {
            guard let url = URL(string: feedURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  RSSDirectFeedProvider.isValidFeedURL(url) else {
                return false
            }
        } else if accountHandle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if triggerMode == .keywords, includeKeywords.isEmpty {
            return false
        }
        return true
    }
}
