// RuntimeState.swift
import Foundation

/// Summary of the most recent monitoring run. Persisted so the menu bar can
/// show a meaningful status (login required, degraded, etc.) after the run ends.
public struct RunSummary: Codable, Equatable, Sendable {
    public var accountsChecked: Int
    public var tweetsFound: Int
    public var eventsGenerated: Int
    public var loginRequired: Bool
    public var actionRequired: String?
    public var rateLimited: Bool
    public var error: String?
    /// When true, the error is transient (e.g. page structure, timeout) and
    /// should not surface as a "degraded" status to the user.
    public var isTransientError: Bool
    /// 源配置缺失/未完成（DESIGN-RSSHUB.md §8.3）：Scheduler 不退避、不循环重试。
    public var configurationRequired: Bool
    public var finishedAt: Date

    // Backward-compatible decoding: older persisted JSON lacks isTransientError.
    private enum CodingKeys: String, CodingKey {
        case accountsChecked, tweetsFound, eventsGenerated
        case loginRequired, actionRequired, rateLimited
        case error, isTransientError, configurationRequired, finishedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountsChecked = try c.decode(Int.self, forKey: .accountsChecked)
        tweetsFound = try c.decode(Int.self, forKey: .tweetsFound)
        eventsGenerated = try c.decode(Int.self, forKey: .eventsGenerated)
        loginRequired = try c.decode(Bool.self, forKey: .loginRequired)
        actionRequired = try c.decodeIfPresent(String.self, forKey: .actionRequired)
        rateLimited = try c.decode(Bool.self, forKey: .rateLimited)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        isTransientError = try c.decodeIfPresent(Bool.self, forKey: .isTransientError) ?? false
        configurationRequired = try c.decodeIfPresent(Bool.self, forKey: .configurationRequired) ?? false
        finishedAt = try c.decode(Date.self, forKey: .finishedAt)
    }

    public init(
        accountsChecked: Int,
        tweetsFound: Int,
        eventsGenerated: Int,
        loginRequired: Bool,
        actionRequired: String?,
        rateLimited: Bool,
        error: String?,
        isTransientError: Bool = false,
        configurationRequired: Bool = false,
        finishedAt: Date
    ) {
        self.accountsChecked = accountsChecked
        self.tweetsFound = tweetsFound
        self.eventsGenerated = eventsGenerated
        self.loginRequired = loginRequired
        self.actionRequired = actionRequired
        self.rateLimited = rateLimited
        self.error = error
        self.isTransientError = isTransientError
        self.configurationRequired = configurationRequired
        self.finishedAt = finishedAt
    }

    public static var empty: RunSummary {
        RunSummary(
            accountsChecked: 0,
            tweetsFound: 0,
            eventsGenerated: 0,
            loginRequired: false,
            actionRequired: nil,
            rateLimited: false,
            error: nil,
            isTransientError: false,
            configurationRequired: false,
            finishedAt: Date()
        )
    }
}

public struct RuntimeState: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var isPaused: Bool
    public var backoffUntil: Date?
    public var accounts: [String: AccountCursor]
    public var lastRunAt: Date?
    public var lastRunSummary: RunSummary?

    public static let `default` = RuntimeState(
        schemaVersion: 1,
        isPaused: false,
        backoffUntil: nil,
        accounts: [:],
        lastRunAt: nil,
        lastRunSummary: nil
    )

    public var status: AppRunStatus {
        if isPaused {
            return .paused
        }
        if let backoff = backoffUntil, backoff > Date() {
            return .backingOff(until: backoff, reason: "请求过于频繁，已退避")
        }
        if let summary = lastRunSummary {
            if summary.configurationRequired {
                // 源配置缺失/未完成：显示为独立状态，而非 degraded（DESIGN-RSSHUB.md §8.3）。
                return .configurationRequired
            }
            if summary.loginRequired {
                return .loginRequired
            }
            if let action = summary.actionRequired {
                return .actionRequired(action)
            }
            if summary.rateLimited {
                if let backoff = backoffUntil {
                    return .backingOff(until: backoff, reason: "请求过于频繁，已退避")
                }
            }
            // Filter out transient failures from showing "运行异常"：
            // 只依据结构化 isTransientError 标志（错误文案匹配已废弃）。
            if let error = summary.error {
                if summary.isTransientError {
                    return .idle(nextRunAt: nil)
                }
                return .degraded(error)
            }
        }
        return .idle(nextRunAt: nil)
    }
}

public struct AccountCursor: Codable, Equatable, Sendable {
    public var seenTweetIDs: [String]
    public var initialized: Bool
    public var lastCheckedAt: Date?
    public var lastSuccessfulFetchAt: Date?
    public var lastErrorCode: String?
    /// Conditional HTTP validators keyed by provider + instance/feed identity.
    public var httpValidators: [String: HTTPValidator]

    public static let empty = AccountCursor(
        seenTweetIDs: [],
        initialized: false,
        lastCheckedAt: nil,
        lastSuccessfulFetchAt: nil,
        lastErrorCode: nil,
        httpValidators: [:]
    )

    public init(
        seenTweetIDs: [String],
        initialized: Bool,
        lastCheckedAt: Date?,
        lastSuccessfulFetchAt: Date?,
        lastErrorCode: String?,
        httpValidators: [String: HTTPValidator] = [:]
    ) {
        self.seenTweetIDs = seenTweetIDs
        self.initialized = initialized
        self.lastCheckedAt = lastCheckedAt
        self.lastSuccessfulFetchAt = lastSuccessfulFetchAt
        self.lastErrorCode = lastErrorCode
        self.httpValidators = httpValidators
    }

    private enum CodingKeys: String, CodingKey {
        case seenTweetIDs, initialized, lastCheckedAt, lastSuccessfulFetchAt, lastErrorCode
        case httpValidators
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seenTweetIDs = try container.decodeIfPresent([String].self, forKey: .seenTweetIDs) ?? []
        self.initialized = try container.decodeIfPresent(Bool.self, forKey: .initialized) ?? false
        self.lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        self.lastSuccessfulFetchAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessfulFetchAt)
        self.lastErrorCode = try container.decodeIfPresent(String.self, forKey: .lastErrorCode)
        self.httpValidators = try container.decodeIfPresent(
            [String: HTTPValidator].self,
            forKey: .httpValidators
        ) ?? [:]
    }

    public var seenTweetIDsSet: Set<String> {
        Set(seenTweetIDs)
    }

    public mutating func addTweetID(_ id: String) {
        seenTweetIDs.append(id)
        // Keep only last 300
        if seenTweetIDs.count > 300 {
            seenTweetIDs.removeFirst(seenTweetIDs.count - 300)
        }
    }
}

public enum AppRunStatus: Equatable, Sendable {
    case idle(nextRunAt: Date?)
    case running(startedAt: Date)
    case paused
    case loginRequired
    case actionRequired(String)
    case backingOff(until: Date, reason: String)
    case degraded(String)
    /// 源配置未完成或缺失：需要用户先配置信源（DESIGN-RSSHUB.md §8.3、约束 11）。
    case configurationRequired

    public var displayName: String {
        switch self {
        case .idle:
            return "运行中"
        case .running:
            return "正在检查"
        case .paused:
            return "暂停"
        case .loginRequired:
            return "需要登录"
        case .actionRequired:
            return "需要用户处理 X 验证"
        case .backingOff(let until, _):
            return "已退避至 \(until.formatted(.dateTime.hour().minute()))"
        case .degraded:
            return "运行异常"
        case .configurationRequired:
            return "需要配置信源"
        }
    }

    /// 用户点击状态提示时应前往的设置 tab（与 SettingsView 的 tab 顺序对应；
    /// nil 表示当前状态无需引导跳转）。菜单栏据此把状态变成可点击的入口。
    public var suggestedSettingsTabIndex: Int? {
        switch self {
        case .configurationRequired:
            return 0 // 信源
        case .loginRequired, .actionRequired:
            return 1 // X 账号
        case .backingOff, .degraded:
            return 3 // 抓取配置（退避/异常时先看频率与状态）
        case .idle, .running, .paused:
            return nil
        }
    }

    /// 该状态下"立即检查"是否注定无法推进（用于禁用按钮并说明原因）。
    public var manualCheckBlockedReason: String? {
        switch self {
        case .configurationRequired:
            return "需先配置信源"
        case .loginRequired:
            return "需先登录 X"
        default:
            return nil
        }
    }
}
