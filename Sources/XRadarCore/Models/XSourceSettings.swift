// XSourceSettings.swift
// 遵循 DESIGN-RSSHUB.md §3.1 / §4.1 / §4.4：
// - TimelineProviderID 区分传输方式（RSSHub vs X WebView），与平台概念分离。
// - XSourcePolicy 决定抓取策略路由。
// - XSourceSettings 聚合策略、RSSHub 实例列表与风险确认。
import Foundation

public enum TimelineProviderID: String, Codable, CaseIterable, Sendable {
    case rssHub
    case xWeb
    case rssFeed

    public var displayName: String {
        switch self {
        case .rssHub:
            return "RSSHub"
        case .xWeb:
            return "X WebView"
        case .rssFeed:
            return "自定义 RSS 源"
        }
    }
}

public enum XSourcePolicy: String, Codable, CaseIterable, Sendable {
    case rssHubOnly
    case xWebOnly
    case rssHubThenXWeb

    public var displayName: String {
        switch self {
        case .rssHubOnly:
            return "RSSHub（推荐）"
        case .xWebOnly:
            return "应用内 X 登录抓取"
        case .rssHubThenXWeb:
            return "RSSHub 失败后回退 X"
        }
    }
}

public struct XSourceSettings: Codable, Equatable, Sendable {
    public var policy: XSourcePolicy
    public var rssHubInstances: [String]
    public var webFallbackRiskAcknowledged: Bool
    public var sourceSetupCompleted: Bool

    public init(
        policy: XSourcePolicy,
        rssHubInstances: [String],
        webFallbackRiskAcknowledged: Bool,
        sourceSetupCompleted: Bool
    ) {
        self.policy = policy
        self.rssHubInstances = rssHubInstances
        self.webFallbackRiskAcknowledged = webFallbackRiskAcknowledged
        self.sourceSetupCompleted = sourceSetupCompleted
    }

    /// 所有规则都被移除（无任何监控账号）。
    public static let `default` = XSourceSettings(
        policy: .rssHubOnly,
        rssHubInstances: [],
        webFallbackRiskAcknowledged: false,
        sourceSetupCompleted: false
    )

    /// 返回是否具备可用的 RSSHub 实例。
    public var hasUsableInstances: Bool {
        !rssHubInstances.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case policy, rssHubInstances, webFallbackRiskAcknowledged, sourceSetupCompleted
    }

    /// Decode every field independently so adding a setting never makes an
    /// otherwise valid configuration unreadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.policy = try container.decodeIfPresent(XSourcePolicy.self, forKey: .policy) ?? .rssHubOnly
        self.rssHubInstances = try container.decodeIfPresent([String].self, forKey: .rssHubInstances) ?? []
        self.webFallbackRiskAcknowledged = try container.decodeIfPresent(
            Bool.self,
            forKey: .webFallbackRiskAcknowledged
        ) ?? false
        self.sourceSetupCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .sourceSetupCompleted
        ) ?? false
    }
}

enum XHostPolicy {
    static func isXHost(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "x.com" || normalized.hasSuffix(".x.com") ||
            normalized == "twitter.com" || normalized.hasSuffix(".twitter.com")
    }
}

// MARK: - 实例 URL 校验与规范化（DESIGN-RSSHUB.md §4.4）

public enum RSSHubInstanceValidationError: Error, Equatable, Sendable {
    case empty
    case missingHost
    case unsupportedScheme
    case containsCredentials
    case containsFragment
    case containsQuery
    case disallowedXHost
}

public enum RSSHubInstanceValidator {
    /// 规范化并校验单个 RSSHub 实例 baseURL。
    /// 允许 https，以及本机自建实例的 http://localhost / 127.0.0.1 / [::1]。
    public static func normalize(_ input: String) -> Result<String, RSSHubInstanceValidationError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return .failure(.missingHost) }

        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return .failure(.missingHost)
        }
        guard let host = url.host, !host.isEmpty else {
            return .failure(.missingHost)
        }
        guard !XHostPolicy.isXHost(host) else {
            return .failure(.disallowedXHost)
        }
        guard url.user == nil && url.password == nil else {
            return .failure(.containsCredentials)
        }
        guard url.fragment == nil else {
            return .failure(.containsFragment)
        }
        guard url.query == nil else {
            return .failure(.containsQuery)
        }
        let isLocalHost = host == "localhost" || host == "127.0.0.1" || host == "[::1]"
        if scheme == "https" {
            // allowed
        } else if scheme == "http" && isLocalHost {
            // allowed
        } else {
            return .failure(.unsupportedScheme)
        }
        return .success(trimmed)
    }

    public static func isUsable(_ input: String) -> Bool {
        (try? normalize(input).get()) != nil
    }
}
