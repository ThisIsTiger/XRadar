// XTimelineRouter.swift
// 带状态的多信源抓取编排（DESIGN-RSSHUB.md §3.3、§7.2、§7.3、§12.4）
import Foundation

/// 按 `XSourcePolicy` 编排 RSSHub / X WebView 抓取。带状态的 actor：
/// 实例健康、冷却和"本轮最多一次 WebView 回退"都在这里管理。
public actor XTimelineRouter {
    private let webViewProvider: any TimelineProvider
    private let healthTracker: InstanceHealthTracker
    /// 为每个实例构造 HTTP 客户端（默认真实客户端；测试注入 URLProtocol stub）。
    private let rssHubClientFactory: @Sendable (String) -> RSSHubHTTPClient
    /// 本轮（一次 runCheck 周期）内是否已经用过一次 WebView 回退。
    private var webViewFallbackUsed = false

    public init(
        webViewProvider: any TimelineProvider,
        healthTracker: InstanceHealthTracker,
        rssHubClientFactory: @escaping @Sendable (String) -> RSSHubHTTPClient = { instanceURL in
            let host = URL(string: instanceURL)?.host
            return RSSHubHTTPClient(expectedHosts: host.map { [$0] } ?? [])
        }
    ) {
        self.webViewProvider = webViewProvider
        self.healthTracker = healthTracker
        self.rssHubClientFactory = rssHubClientFactory
    }

    /// 新一轮开始（Pipeline 的 runCheck 入口调用），重置"本轮回退"标记。
    public func beginRound() {
        webViewFallbackUsed = false
    }

    /// 按策略抓取。`cursorInitialized` 用于区分可疑空 Feed 与未验证空 Feed（§6.1）。
    public func fetch(
        _ request: TimelineRequest,
        settings: XSourceSettings,
        cursorInitialized: Bool
    ) async throws -> TimelineFetchResult {
        switch settings.policy {
        case .rssHubOnly:
            return try await fetchRSSHub(
                request, settings: settings, cursorInitialized: cursorInitialized,
                allowFallback: false
            )

        case .xWebOnly:
            return try await fetchWebView(request, fallbackFrom: nil)

        case .rssHubThenXWeb:
            guard settings.webFallbackRiskAcknowledged else {
                // 配置层禁止未确认风险时保存该策略；这里是防御性兜底。
                return try await fetchRSSHub(
                    request, settings: settings, cursorInitialized: cursorInitialized,
                    allowFallback: false
                )
            }
            do {
                return try await fetchRSSHub(
                    request, settings: settings, cursorInitialized: cursorInitialized,
                    allowFallback: true
                )
            } catch {
                guard Self.isFallbackEligible(error),
                      !webViewFallbackUsed else {
                    throw error
                }
                webViewFallbackUsed = true
                return try await fetchWebView(request, fallbackFrom: .rssHub)
            }
        }
    }

    // MARK: - RSSHub 分支

    private func fetchRSSHub(
        _ request: TimelineRequest,
        settings: XSourceSettings,
        cursorInitialized: Bool,
        allowFallback: Bool
    ) async throws -> TimelineFetchResult {
        let instances = settings.rssHubInstances
        guard !instances.isEmpty else {
            throw SourceError.configurationRequired
        }

        let usable = await healthTracker.usableInstances(instances)
        guard !usable.isEmpty else {
            // 全部在冷却中：抛专用错误（§7.2），避免每个账号重复轰炸实例。
            var lastKnownError: String?
            for instance in instances {
                if let error = await healthTracker.state(of: instance)?.lastError {
                    lastKnownError = error
                }
            }
            throw SourceError.instancesCoolingDown(lastError: lastKnownError)
        }

        var lastError: Error = SourceError.networkUnavailable(provider: .rssHub)
        for instance in usable {
            let provider = RSSHubTimelineProvider(
                instanceURL: instance,
                client: rssHubClientFactory(instance)
            )
            do {
                let result = try await provider.fetch(request)

                // HTTP 304 → 健康的 .notModified（§6.1）：无新内容，不是空 Feed。
                if result.feedState == .notModified {
                    await healthTracker.recordSuccess(instance)
                    return result
                }

                // 空 Feed 判定（§6.1）：2xx + rawItemCount==0 不可信。
                if result.rawItemCount == 0 {
                    if cursorInitialized {
                        await healthTracker.recordFailure(
                            instance, cause: .suspiciousEmpty,
                            error: "可疑空 Feed（已初始化）"
                        )
                        lastError = SourceError.suspiciousEmpty
                        continue
                    } else {
                        await healthTracker.recordFailure(
                            instance, cause: .emptyUnverified,
                            error: "空 Feed（未建立基线）"
                        )
                        lastError = SourceError.emptyUnverified
                        continue
                    }
                }

                await healthTracker.recordSuccess(instance)
                return result
            } catch SourceError.accountUnavailable {
                // 账号不存在/不可用：换实例无意义，直接失败。
                await healthTracker.recordFailure(
                    instance, cause: .serverError,
                    error: "账号不可用"
                )
                throw SourceError.accountUnavailable(statusCode: 404)
            } catch {
                lastError = error
                await healthTracker.recordFailure(
                    instance,
                    cause: Self.cooldownCause(for: error),
                    error: error.localizedDescription
                )
                continue
            }
        }
        throw lastError
    }

    // MARK: - WebView 分支

    private func fetchWebView(
        _ request: TimelineRequest,
        fallbackFrom: TimelineProviderID?
    ) async throws -> TimelineFetchResult {
        do {
            let result = try await webViewProvider.fetch(request)
            return TimelineFetchResult(
                tweets: result.tweets,
                providerID: .xWeb,
                instanceHost: nil,
                fallbackFromProviderID: fallbackFrom,
                rawItemCount: result.rawItemCount,
                feedState: result.feedState
            )
        } catch let timelineError as TimelineError {
            throw Self.webViewError(timelineError)
        }
    }

    /// 把 WebView 的 DOM 层错误转换为统一 SourceError（§7.1）。
    static func webViewError(_ error: TimelineError) -> SourceError {
        switch error {
        case .authenticationRequired:
            return .authenticationRequired(provider: .xWeb)
        case .userActionRequired(let message):
            return .userActionRequired(message)
        case .rateLimited(let retryAfter):
            return .rateLimited(provider: .xWeb, retryAfter: retryAfter)
        case .pageLoadTimeout, .pageStructureChanged, .networkUnavailable:
            return .networkUnavailable(provider: .xWeb)
        }
    }

    // MARK: - 冷却与回退判定

    static func cooldownCause(for error: Error) -> InstanceHealthTracker.CooldownCause {
        switch error as? SourceError {
        case .rateLimited(_, let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .invalidFeed:
            return .invalidFeed
        case .suspiciousEmpty:
            return .suspiciousEmpty
        case .emptyUnverified:
            return .emptyUnverified
        case .requestTimeout, .networkUnavailable, .accountUnavailable:
            return .network
        default:
            return .serverError
        }
    }

    /// 是否允许回退到 X WebView（§7.3）。
    static func isFallbackEligible(_ error: Error) -> Bool {
        guard let sourceError = error as? SourceError else { return false }
        switch sourceError {
        case .requestTimeout, .networkUnavailable, .rateLimited,
             .invalidFeed, .suspiciousEmpty, .emptyUnverified,
             .instancesCoolingDown:
            return true
        case .configurationRequired, .invalidInstanceURL,
             .accountUnavailable, .responseTooLarge, .redirectRejected,
             .httpStatus, .authenticationRequired, .userActionRequired:
            return false
        }
    }
}
