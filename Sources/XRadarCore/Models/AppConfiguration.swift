// AppConfiguration.swift
import Foundation

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var pollInterval: PollingInterval
    public var runCheckAtLaunch: Bool
    public var runCheckAfterWake: Bool
    public var launchAtLogin: Bool
    public var historyRetentionDays: Int
    public var maxRecentEvents: Int
    public var webViewProviderAcknowledged: Bool
    public var macOSNotificationsEnabled: Bool
    public var macOSNotificationSoundEnabled: Bool
    public var telegramEnabled: Bool
    public var rules: [MonitorRule]
    /// DESIGN-RSSHUB.md §4.1；schema v2 新增
    public var xSourceSettings: XSourceSettings

    public static let `default` = AppConfiguration(
        schemaVersion: 2,
        pollInterval: .fiveMinutes,
        runCheckAtLaunch: true,
        runCheckAfterWake: true,
        launchAtLogin: false,
        historyRetentionDays: 30,
        maxRecentEvents: 500,
        webViewProviderAcknowledged: false,
        macOSNotificationsEnabled: true,
        macOSNotificationSoundEnabled: true,
        telegramEnabled: false,
        rules: [],
        xSourceSettings: .default
    )

    public init(
        schemaVersion: Int = 2,
        pollInterval: PollingInterval,
        runCheckAtLaunch: Bool,
        runCheckAfterWake: Bool,
        launchAtLogin: Bool,
        historyRetentionDays: Int,
        maxRecentEvents: Int,
        webViewProviderAcknowledged: Bool,
        macOSNotificationsEnabled: Bool,
        macOSNotificationSoundEnabled: Bool,
        telegramEnabled: Bool,
        rules: [MonitorRule],
        xSourceSettings: XSourceSettings
    ) {
        self.schemaVersion = schemaVersion
        self.pollInterval = pollInterval
        self.runCheckAtLaunch = runCheckAtLaunch
        self.runCheckAfterWake = runCheckAfterWake
        self.launchAtLogin = launchAtLogin
        self.historyRetentionDays = historyRetentionDays
        self.maxRecentEvents = maxRecentEvents
        self.webViewProviderAcknowledged = webViewProviderAcknowledged
        self.macOSNotificationsEnabled = macOSNotificationsEnabled
        self.macOSNotificationSoundEnabled = macOSNotificationSoundEnabled
        self.telegramEnabled = telegramEnabled
        self.rules = rules
        self.xSourceSettings = xSourceSettings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pollInterval, runCheckAtLaunch, runCheckAfterWake
        case launchAtLogin, historyRetentionDays, maxRecentEvents
        case webViewProviderAcknowledged, macOSNotificationsEnabled
        case macOSNotificationSoundEnabled, telegramEnabled, rules, xSourceSettings
    }

    // 无损迁移 v1 → v2（DESIGN-RSSHUB.md §4.2）：
    // - v1 配置文件缺失 xSourceSettings：判定为迁移用户，保持 WebView 行为，
    //   但 sourceSetupCompleted = false，暂停调度直到用户在 UI 完成选择。
    // - 所有字段 decodeIfPresent，解码失败不得导致 Repository 退回 .default。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        pollInterval = try c.decodeIfPresent(PollingInterval.self, forKey: .pollInterval) ?? .fiveMinutes
        runCheckAtLaunch = try c.decodeIfPresent(Bool.self, forKey: .runCheckAtLaunch) ?? true
        runCheckAfterWake = try c.decodeIfPresent(Bool.self, forKey: .runCheckAfterWake) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        historyRetentionDays = try c.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 30
        maxRecentEvents = try c.decodeIfPresent(Int.self, forKey: .maxRecentEvents) ?? 500
        webViewProviderAcknowledged = try c.decodeIfPresent(Bool.self, forKey: .webViewProviderAcknowledged) ?? false
        macOSNotificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .macOSNotificationsEnabled) ?? true
        macOSNotificationSoundEnabled = try c.decodeIfPresent(Bool.self, forKey: .macOSNotificationSoundEnabled) ?? true
        telegramEnabled = try c.decodeIfPresent(Bool.self, forKey: .telegramEnabled) ?? false
        rules = try c.decodeIfPresent([MonitorRule].self, forKey: .rules) ?? []

        if let settings = try c.decodeIfPresent(XSourceSettings.self, forKey: .xSourceSettings) {
            xSourceSettings = settings
        } else {
            // v1 迁移：保留原 WebView 行为，但未完成源配置（阻塞调度，约束 11）。
            xSourceSettings = XSourceSettings(
                policy: .xWebOnly,
                rssHubInstances: [],
                webFallbackRiskAcknowledged: false,
                sourceSetupCompleted: false
            )
        }
    }
}

public enum PollingInterval: Int, Codable, CaseIterable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case tenMinutes = 600
    case thirtyMinutes = 1800
    case sixtyMinutes = 3600

    public var displayName: String {
        switch self {
        case .oneMinute:
            return "1 分钟"
        case .fiveMinutes:
            return "5 分钟"
        case .tenMinutes:
            return "10 分钟"
        case .thirtyMinutes:
            return "30 分钟"
        case .sixtyMinutes:
            return "60 分钟"
        }
    }

    public var duration: Duration {
        .seconds(rawValue)
    }
}

// MARK: - 可选间隔集合（DESIGN-RSSHUB.md §4.3）
// 一分钟仅保留解码旧配置的能力，UI 不再提供（由 TASK-08 使用）。

public extension PollingInterval {
    /// UI 可选择的最小/可选间隔集合：1 分钟选项被隐藏。
    static let selectableCases: [PollingInterval] = [.fiveMinutes, .tenMinutes, .thirtyMinutes, .sixtyMinutes]
}