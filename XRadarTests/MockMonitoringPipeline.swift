// MockMonitoringPipeline.swift
//
// Shared mock pipeline used by the scheduler and persistence tests. It records
// concurrency so the scheduler's single-in-flight guard can be asserted, and
// lets a test inject a fixed `PollRunSummary` to drive status propagation.
import Foundation
@testable import XRadarCore

actor MockMonitoringPipeline: MonitoringPipelineType {
    var nextSummary: PollRunSummary?
    var callCount = 0
    var activeCount = 0
    var maxConcurrent = 0
    var lastRules: [MonitorRule] = []
    var lastCursors: [String: AccountCursor] = []
    var lastSourceSettings: XSourceSettings = .default

    func setNextSummary(_ summary: PollRunSummary?) async {
        nextSummary = summary
    }

    func runCheck(
        reason: TriggerReason,
        rules: [MonitorRule],
        accountCursors: [String: AccountCursor],
        sourceSettings: XSourceSettings
    ) async -> PollRunSummary {
        callCount += 1
        activeCount += 1
        maxConcurrent = max(maxConcurrent, activeCount)
        lastRules = rules
        lastCursors = accountCursors
        lastSourceSettings = sourceSettings

        // Simulate work; if two passes overlapped this would exceed 1.
        try? await Task.sleep(nanoseconds: 30_000_000)

        activeCount -= 1

        if let summary = nextSummary {
            return summary
        }
        return PollRunSummary(
            startTime: Date(),
            endTime: Date(),
            accountsChecked: rules.count,
            tweetsFound: 0,
            eventsGenerated: 0,
            loginRequired: false,
            actionRequired: nil,
            rateLimited: false,
            error: nil,
            isTransientError: false,
            accountCursors: accountCursors
        )
    }
}
