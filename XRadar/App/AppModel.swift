// AppModel.swift
import Foundation
import SwiftUI
import XRadarCore

@MainActor
class AppModel: ObservableObject {
    @Published var configuration: AppConfiguration
    @Published var runtimeState: RuntimeState
    @Published var events: [NotificationEvent] = []
    @Published var fetchRecords: [FetchRecord] = []

    let configRepository: ConfigurationRepository
    let stateRepository: StateRepository
    let eventRepository: EventRepository
    let fetchHistoryRepository: FetchHistoryRepository
    let xSession: XSession
    let notificationGateway: NotificationGateway
    private var scheduler: PollScheduler!
    private var pipeline: MonitoringPipeline!
    private var wakeObserver: WakeObserver?
    private var reloadTask: Task<Void, Never>?

    init() {
        // Initialize repositories
        self.configRepository = ConfigurationRepository()
        self.stateRepository = StateRepository()
        self.eventRepository = EventRepository()
        self.fetchHistoryRepository = FetchHistoryRepository()
        self.xSession = XSession()

        // Load or create default configuration
        self.configuration = .default
        self.runtimeState = .default

        // Initialize notifications
        let macOSNotifier = MacOSLocalNotifier()
        let telegramNotifier = TelegramNotifier()
        self.notificationGateway = NotificationGateway(
            channels: [macOSNotifier, telegramNotifier]
        )

        // Initialize pipeline and scheduler
        // RSSHub 实例跨轮复用一个 InstanceHealthTracker，各轮配置快照由 Scheduler 传入（§8.1）。
        let healthTracker = InstanceHealthTracker()
        let router = XTimelineRouter(
            webViewProvider: WebViewTimelineProvider(xSession: xSession),
            healthTracker: healthTracker
        )
        self.pipeline = MonitoringPipeline(
            router: router,
            ruleEngine: RuleEngine(),
            eventRepository: eventRepository,
            notificationGateway: notificationGateway,
            fetchHistoryRepository: fetchHistoryRepository
        )

        self.scheduler = PollScheduler(
            pipeline: pipeline,
            stateRepository: stateRepository,
            configRepository: configRepository
        )

        // Wake observer for Mac sleep/wake
        self.wakeObserver = WakeObserver { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.configuration.runCheckAfterWake {
                    await self.scheduler.triggerNow(reason: .wake)
                }
            }
        }

        // Setup
        setupEventReloadTimer()
        requestNotificationPermission()

        // Load initial data
        Task {
            await loadInitialData()
        }
    }

    private func loadInitialData() async {
        configuration = await configRepository.load()
        runtimeState = await stateRepository.load()
        events = await eventRepository.loadEvents()
        fetchRecords = await fetchHistoryRepository.loadRecords()

        // 启动时把用户配置的保留策略同步给事件仓库（否则旋钮不生效）。
        eventRepository.updatePolicy(
            maxEvents: configuration.maxRecentEvents,
            retentionDays: configuration.historyRetentionDays
        )

        // 启动时同步通知渠道开关与声音设置（否则投递层全通道常开，开关无效）。
        await notificationGateway.configure(
            macOSEnabled: configuration.macOSNotificationsEnabled,
            macOSSoundEnabled: configuration.macOSNotificationSoundEnabled,
            telegramEnabled: configuration.telegramEnabled
        )

        // Always resume monitoring on launch — a persisted "paused" state from a
        // previous session should not silently block all future polling.
        if runtimeState.isPaused {
            runtimeState.isPaused = false
            await stateRepository.save(runtimeState)
        }
        await scheduler.start()

        if configuration.runCheckAtLaunch {
            await scheduler.triggerNow(reason: .launch)
        }
    }

    private func setupEventReloadTimer() {
        reloadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                await self.reloadEvents()
                await self.reloadFetchRecords()
            }
        }
    }

    func reloadEvents() async {
        events = await eventRepository.loadEvents()
    }

    func reloadFetchRecords() async {
        fetchRecords = await fetchHistoryRepository.loadRecords()
    }

    func clearFetchHistory() {
        Task {
            await fetchHistoryRepository.clear()
            await reloadFetchRecords()
        }
    }

    func deleteEvent(_ event: NotificationEvent) {
        Task {
            await eventRepository.deleteEvent(event)
            await reloadEvents()
        }
    }

    private func requestNotificationPermission() {
        guard configuration.macOSNotificationsEnabled else { return }
        Task {
            await notificationGateway.requestPermissions()
        }
    }

    func addRule(_ rule: MonitorRule) {
        configuration.rules.append(rule)
        saveConfiguration()
    }

    func updateRule(_ rule: MonitorRule) {
        if let index = configuration.rules.firstIndex(where: { $0.id == rule.id }) {
            configuration.rules[index] = rule
            saveConfiguration()
        }
    }

    func deleteRule(_ rule: MonitorRule) {
        configuration.rules.removeAll { $0.id == rule.id }
        saveConfiguration()
    }

    func updatePollingInterval(_ interval: PollingInterval) {
        configuration.pollInterval = interval
        Task {
            await configRepository.save(configuration)
            await scheduler.restart(interval: interval.duration)
        }
    }

    // MARK: - 布尔/数值设置 setter（统一落盘，视图禁止直接绑定 configuration）

    func setRunCheckAtLaunch(_ value: Bool) {
        configuration.runCheckAtLaunch = value
        saveConfiguration()
    }

    func setMacOSNotificationsEnabled(_ value: Bool) {
        configuration.macOSNotificationsEnabled = value
        if value {
            Task { await notificationGateway.requestPermissions() }
        }
        applyNotificationPolicy()
        saveConfiguration()
    }

    func setMacOSNotificationSoundEnabled(_ value: Bool) {
        configuration.macOSNotificationSoundEnabled = value
        applyNotificationPolicy()
        saveConfiguration()
    }

    func setTelegramEnabled(_ value: Bool) {
        configuration.telegramEnabled = value
        applyNotificationPolicy()
        saveConfiguration()
    }

    /// 把通知渠道开关/声音同步给投递网关（投递层据此过滤通道）。
    private func applyNotificationPolicy() {
        Task {
            await notificationGateway.configure(
                macOSEnabled: configuration.macOSNotificationsEnabled,
                macOSSoundEnabled: configuration.macOSNotificationSoundEnabled,
                telegramEnabled: configuration.telegramEnabled
            )
        }
    }

    func setRunCheckAfterWake(_ value: Bool) {
        configuration.runCheckAfterWake = value
        saveConfiguration()
    }

    /// SMAppService 注册由视图侧处理；这里负责配置持久化。
    func setLaunchAtLogin(enabled: Bool) {
        configuration.launchAtLogin = enabled
        saveConfiguration()
    }

    func setHistoryRetentionDays(_ days: Int) {
        configuration.historyRetentionDays = days
        applyEventPolicy()
        saveConfiguration()
    }

    func setMaxRecentEvents(_ limit: Int) {
        configuration.maxRecentEvents = limit
        applyEventPolicy()
        saveConfiguration()
    }

    /// 把保留天数/事件上限同步给事件仓库（抓取诊断记录有自己的固定窗口）。
    private func applyEventPolicy() {
        eventRepository.updatePolicy(
            maxEvents: configuration.maxRecentEvents,
            retentionDays: configuration.historyRetentionDays
        )
    }

    func togglePause() {
        runtimeState.isPaused.toggle()
        saveRuntimeState()

        Task {
            if runtimeState.isPaused {
                await scheduler.stop()
            } else {
                await scheduler.start()
            }
        }
    }

    func triggerNow() {
        Task {
            await scheduler.triggerNow(reason: .manual)
        }
    }

    func presentLogin() {
        Task {
            await xSession.presentLogin()
        }
    }

    func logout() {
        Task {
            try? await xSession.logout()
            runtimeState = RuntimeState.default
            saveRuntimeState()
        }
    }

    // MARK: - 信源设置（DESIGN-RSSHUB.md §10.1、§10.2）

    /// 设置页顶部展示的当前信源健康状态摘要。
    var sourceHealthSummary: String {
        let settings = configuration.xSourceSettings
        let feedCount = configuration.rules.filter { $0.enabled && $0.feedURL != nil }.count
        if feedCount > 0 {
            return "自定义 RSS 源已配置（\(feedCount) 个），自动抓取已启用"
        }
        if !settings.sourceSetupCompleted {
            return "信源配置未完成，已暂停自动抓取"
        }
        switch settings.policy {
        case .rssHubOnly, .rssHubThenXWeb:
            if settings.rssHubInstances.isEmpty {
                return "未配置 RSSHub 实例"
            }
            if let summary = runtimeState.lastRunSummary,
               let error = summary.error, !summary.isTransientError {
                return "RSSHub 抓取异常：\(error)"
            }
            return "RSSHub 已配置（\(settings.rssHubInstances.count) 个实例）"
        case .xWebOnly:
            if !xSession.state.isLoggedIn {
                return "X 尚未登录，需要登录后抓取"
            }
            return "应用内 X 登录抓取"
        }
    }

    /// 保存后按策略自动推导 `sourceSetupCompleted`（约束 11）。
    func applySourceSettings() {
        var settings = configuration.xSourceSettings
        switch settings.policy {
        case .rssHubOnly:
            settings.sourceSetupCompleted = !settings.rssHubInstances.isEmpty
        case .xWebOnly:
            settings.sourceSetupCompleted = true
        case .rssHubThenXWeb:
            settings.sourceSetupCompleted = !settings.rssHubInstances.isEmpty && settings.webFallbackRiskAcknowledged
        }
        configuration.xSourceSettings = settings
        saveConfiguration()
    }

    func updateSourcePolicy(_ policy: XSourcePolicy) {
        configuration.xSourceSettings.policy = policy
        if policy != .rssHubThenXWeb {
            configuration.xSourceSettings.webFallbackRiskAcknowledged = false
        }
        applySourceSettings()
    }

    func setWebFallbackRiskAcknowledged(_ acknowledged: Bool) {
        configuration.xSourceSettings.webFallbackRiskAcknowledged = acknowledged
        applySourceSettings()
    }

    /// 校验并添加一个 RSSHub 实例。返回错误文案；成功返回 nil。
    func addRSSHubInstance(_ rawInput: String) -> String? {
        switch RSSHubInstanceValidator.normalize(rawInput) {
        case .success(let url):
            guard !configuration.xSourceSettings.rssHubInstances.contains(url) else {
                return "实例已存在"
            }
            configuration.xSourceSettings.rssHubInstances.append(url)
            applySourceSettings()
            return nil
        case .failure:
            return "实例地址无效：需要 https，或本机 http://localhost"
        }
    }

    func removeRSSHubInstance(_ url: String) {
        configuration.xSourceSettings.rssHubInstances.removeAll { $0 == url }
        applySourceSettings()
    }

    func moveRSSHubInstance(fromOffsets: IndexSet, toOffset: Int) {
        configuration.xSourceSettings.rssHubInstances.move(fromOffsets: fromOffsets, toOffset: toOffset)
        applySourceSettings()
    }

    /// 无副作用信源测试（§10.1）：只抓取一次并解析，不写 Cursor/历史/事件，
    /// 通知与回退都不会发生。
    func testSource(accountHandle: String) async -> SourceTestResult {
        var result = SourceTestResult()
        let instances = configuration.xSourceSettings.rssHubInstances
        guard !instances.isEmpty, let instance = instances.first else {
            result.error = "未配置 RSSHub 实例"
            return result
        }
        guard RSSHubInstanceValidator.isUsable(instance) else {
            result.error = "实例地址无效"
            return result
        }

        let start = Date()
        do {
            let host = URL(string: instance)?.host
            let client = RSSHubHTTPClient(expectedHosts: Set(host.map { [$0] } ?? []))
            let url = try RSSHubRequestBuilder().makeURL(
                baseURL: instance,
                handle: accountHandle,
                includeReplies: false,
                includeReposts: false,
                maximumCount: 10
            )
            let http = try await client.get(request: URLRequest(url: url))
            result.instanceHost = http.finalURL?.host
            result.statusCode = http.statusCode
            if !http.notModified {
                let parsed = try XRSSParser.parse(
                    data: http.body,
                    requestHandle: accountHandle,
                    maximumCount: 10,
                    now: Date()
                )
                result.rawItemCount = parsed.rawItemCount
                result.validTweetCount = parsed.tweets.count
                result.latestPublishedAt = parsed.tweets.first?.publishedAt
            } else {
                result.rawItemCount = 0
            }
        } catch SourceError.accountUnavailable(let statusCode) {
            result.statusCode = statusCode
            result.error = "账号不可用（HTTP \(statusCode)）"
        } catch {
            result.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        result.duration = Date().timeIntervalSince(start)
        return result
    }

    private func saveConfiguration() {
        Task {
            await configRepository.save(configuration)
        }
    }

    private func saveRuntimeState() {
        Task {
            await stateRepository.save(runtimeState)
        }
    }
}

struct SourceTestResult {
    var instanceHost: String?
    var statusCode: Int?
    var rawItemCount: Int?
    var validTweetCount: Int?
    var latestPublishedAt: Date?
    var duration: TimeInterval?
    var error: String?
}
