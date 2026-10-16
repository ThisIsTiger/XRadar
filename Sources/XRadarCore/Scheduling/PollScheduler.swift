// PollScheduler.swift
import Foundation

public actor PollScheduler {
    private let pipeline: any MonitoringPipelineType
    private let stateRepository: StateRepository
    private let configRepository: ConfigurationRepository
    /// 可注入随机数源（§8.2）：默认均匀 0..<1；测试注入固定值保证边界可断言。
    private let jitterSource: @Sendable () -> Double

    private var pollingTask: Task<Void, Never>?
    private var isPaused = false
    private var currentInterval: Duration = .seconds(300)
    private var backoffUntil: Date?
    private var shouldRunNow = false
    private var skipFirstCheck = false

    // Single in-flight guard. `runCheck` sets this synchronously before any
    // await, so a concurrent invocation bails immediately. The loop also checks
    // `shouldRunNow` each iteration, so a deferred request is still honored.
    private var isChecking = false

    // Wake signal: lets triggerNow interrupt the sleep between runs without a
    // busy loop.
    private let wakeStream: AsyncStream<Void>
    private let wakeContinuation: AsyncStream<Void>.Continuation

    // Live status broadcast (Sendable continuation consumed on the MainActor).
    private var statusContinuation: AsyncStream<SchedulerStatus>.Continuation?

    public init(
        pipeline: any MonitoringPipelineType,
        stateRepository: StateRepository,
        configRepository: ConfigurationRepository,
        jitterSource: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.pipeline = pipeline
        self.stateRepository = stateRepository
        self.configRepository = configRepository
        self.jitterSource = jitterSource

        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        self.wakeStream = stream
        self.wakeContinuation = continuation
    }

    /// 计划任务的 ±20% 抖动（DESIGN-RSSHUB.md §8.2）。`random` 取 0..<1。
    static func jitteredInterval(base: TimeInterval, random: Double) -> TimeInterval {
        let clamped = min(max(random, 0), 1)
        return base * (0.8 + 0.4 * clamped)
    }

    // MARK: - Public control surface

    public func setStatusContinuation(_ continuation: AsyncStream<SchedulerStatus>.Continuation) {
        self.statusContinuation = continuation
    }

    public func start() async {
        guard pollingTask == nil else { return }
        isPaused = false
        shouldRunNow = false
        backoffUntil = nil
        let configuration = await configRepository.load()
        currentInterval = configuration.pollInterval.duration
        skipFirstCheck = !configuration.runCheckAtLaunch

        // Just mark as idle, don't auto-run
        statusContinuation?.yield(.idle)

        // Start the polling loop
        pollingTask = Task {
            await runLoop()
        }
    }

    public func stop() {
        isPaused = true
        backoffUntil = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func restart(interval: Duration) async {
        currentInterval = interval
        stop()
        await start()
    }

    /// Ask the loop to perform an immediate check. If the loop is sleeping it is
    /// woken via the wake stream; if a check is already in flight the request is
    /// coalesced via `shouldRunNow` and the loop will pick it up on the next
    /// iteration. Paused schedulers never run checks — neither from the UI's
    /// manual trigger nor from the wake observer.
    public func triggerNow(reason: TriggerReason) async {
        // 暂停状态下一律拒绝（stop() 已置位）：否则手动检查/唤醒检查会绕过暂停。
        guard !isPaused else { return }
        shouldRunNow = true
        wakeContinuation.yield(())
        // If the polling loop is not yet running (e.g. scheduler not started),
        // fall back to a direct check so callers always get prompt execution.
        guard pollingTask != nil else {
            await runCheck(reason: reason)
            return
        }
    }

    // MARK: - Loop

    // Internal (not private) so tests can observe loop behavior via runCheck calls.
    internal func runLoop() async {
        while !Task.isCancelled, !isPaused {
            var lastReason: TriggerReason = .scheduled
            if skipFirstCheck {
                skipFirstCheck = false
            } else {
                let reason: TriggerReason = shouldRunNow ? .manual : .scheduled
                shouldRunNow = false
                lastReason = reason
                await runCheck(reason: reason)
            }

            // §8.2：只有"计划任务"后的等待加抖动；手动/启动/唤醒检查立即执行、
            // 不加抖动。backoff 截止时间不再二次加抖动。
            await sleepUntilNextRun(applyJitter: lastReason == .scheduled)
        }
    }

    private func sleepUntilNextRun(applyJitter: Bool) async {
        let target: Date
        if let backoff = backoffUntil, backoff > Date() {
            target = backoff
        } else {
            let base = TimeInterval(currentInterval.components.seconds)
            let delay = applyJitter ? Self.jitteredInterval(base: base, random: jitterSource()) : base
            target = Date().addingTimeInterval(delay)
        }

        // Capture actor-isolated values before spawning child tasks.
        let stream = wakeStream
        let tick = Duration.seconds(1)

        // Wait for the interval, but wake early when triggerNow fires. The wait
        // is broken into 1s ticks so we never spin, and a separate child task
        // watches the wake stream so an immediate check is applied promptly.
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    let remaining = target.timeIntervalSinceNow
                    if remaining <= 0 { return }
                    let step = min(Duration.seconds(remaining), tick)
                    do {
                        try await Task.sleep(for: step)
                    } catch {
                        return
                    }
                }
            }
            group.addTask {
                for await _ in stream {
                    return
                }
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Check

    /// Perform a single monitoring pass. Guarded by `isChecking` so concurrent
    /// callers (loop auto-run + `triggerNow` wake, or externally driven tests)
    /// never overlap — only one pass is ever in flight. Declared `internal`
    /// (rather than `private`) so the scheduler reentrancy guarantee is covered
    /// by unit tests via `@testable` import.
    func runCheck(reason: TriggerReason) async {
        // Single in-flight guard (set synchronously before any await).
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        statusContinuation?.yield(.checking)

        // Load the latest configuration and persisted state.
        let configuration = await configRepository.load()
        var runtimeState = await stateRepository.load()

        // 约束 11 / TASK-07：源配置未完成时禁止一切检查（自动 + 手动立即检查）。
        // §13：自定义 RSS 源不依赖 RSSHub 实例/X 登录，存在已启用的 feed 规则即可检查。
        let hasEnabledFeedRules = configuration.rules.contains { $0.enabled && $0.feedURL != nil }
        guard configuration.xSourceSettings.sourceSetupCompleted || hasEnabledFeedRules else {
            statusContinuation?.yield(.configurationRequired)
            return
        }

        let summary = await pipeline.runCheck(
            reason: reason,
            rules: configuration.rules,
            accountCursors: runtimeState.accounts,
            sourceSettings: configuration.xSourceSettings
        )

        // Persist updated cursors so dedup survives restarts.
        runtimeState.accounts = mergeCursors(runtimeState.accounts, summary.accountCursors)
        runtimeState.lastRunAt = summary.endTime
        runtimeState.lastRunSummary = RunSummary(
            accountsChecked: summary.accountsChecked,
            tweetsFound: summary.tweetsFound,
            eventsGenerated: summary.eventsGenerated,
            loginRequired: summary.loginRequired,
            actionRequired: summary.actionRequired,
            rateLimited: summary.rateLimited,
            error: summary.error,
            isTransientError: summary.isTransientError,
            configurationRequired: summary.configurationRequired,
            finishedAt: summary.endTime
        )

        // Backoff handling（§8.3，source-aware）。
        if summary.configurationRequired {
            // 配置缺失：状态为"需要配置信源"，不循环重试，也不进入退避。
            runtimeState.backoffUntil = nil
            backoffUntil = nil
        } else if summary.rateLimited {
            // RSSHub 全部 429：使用最早可重试时间（Retry-After）；X 沿用 15 分钟。
            let until = summary.rateLimitedUntil ?? Date().addingTimeInterval(15 * 60)
            runtimeState.backoffUntil = until
            backoffUntil = until
        } else if summary.isTransientError {
            // A page-rendering failure is also not a reason to immediately
            // hammer the same route again. Let WebKit/X recover first.
            let until = Date().addingTimeInterval(2 * 60)
            runtimeState.backoffUntil = until
            backoffUntil = until
        } else {
            runtimeState.backoffUntil = nil
            backoffUntil = nil
        }

        await stateRepository.save(runtimeState)

        // Broadcast status for the UI.
        if summary.configurationRequired {
            statusContinuation?.yield(.configurationRequired)
        } else if summary.loginRequired {
            statusContinuation?.yield(.loginRequired)
        } else if let action = summary.actionRequired {
            statusContinuation?.yield(.actionRequired(action))
        } else if summary.rateLimited {
            statusContinuation?.yield(.backingOff(until: backoffUntil ?? Date()))
        } else if let error = summary.error {
            statusContinuation?.yield(.degraded(error))
        } else {
            statusContinuation?.yield(.idle)
        }
    }

    /// Merge freshly computed cursors into the existing map, preferring the
    /// updated cursor when present.
    private func mergeCursors(
        _ existing: [String: AccountCursor],
        _ updated: [String: AccountCursor]
    ) -> [String: AccountCursor] {
        var merged = existing
        for (handle, cursor) in updated {
            merged[handle] = cursor
        }
        return merged
    }
}

public enum TriggerReason: Sendable {
    case scheduled
    case manual
    case launch
    case wake
}

/// Live status emitted by the scheduler for the UI layer.
public enum SchedulerStatus: Sendable {
    case checking
    case idle
    case backingOff(until: Date)
    case loginRequired
    case actionRequired(String)
    case degraded(String)
    /// 源配置未完成或彻底缺失（§8.3、约束 11）：需要用户先配置信源。
    case configurationRequired
}
