// SchedulerReentrancyTests.swift
//
// Verifies the scheduler's single-in-flight guarantee: no matter how many
// concurrent `runCheck` calls arrive (loop auto-run + manual trigger, or ten
// tasks firing at once), only ONE monitoring pass executes at a time. This is
// the defense against duplicate timers, concurrent fetches, and busy loops.
import Foundation
import XCTest
@testable import XRadarCore

@MainActor
final class SchedulerReentrancyTests: XCTestCase {
    var tempDir: URL!
    var pipeline: MockMonitoringPipeline!
    var repo: StateRepository!
    var configRepo: ConfigurationRepository!
    var scheduler: PollScheduler!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // 源配置未完成时 Scheduler 禁止检查（约束 11），先写一份已完成配置。
        var config = AppConfiguration.default
        config.xSourceSettings = XSourceSettings(
            policy: .xWebOnly, rssHubInstances: [],
            webFallbackRiskAcknowledged: false, sourceSetupCompleted: true
        )
        try? await JSONFileStore(baseDirectory: tempDir).write(config, to: "config.json")
        pipeline = MockMonitoringPipeline()
        repo = StateRepository(store: JSONFileStore(baseDirectory: tempDir))
        configRepo = ConfigurationRepository(store: JSONFileStore(baseDirectory: tempDir))
        scheduler = PollScheduler(
            pipeline: pipeline,
            stateRepository: repo,
            configRepository: configRepo
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testOnlyOneRunCheckInFlight() async {
        // Fire a burst of concurrent checks. `PollScheduler` is an actor, so it
        // can be captured by the @Sendable task closure without capturing the
        // (non-Sendable) test instance.
        let scheduler = self.scheduler!
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { await scheduler.runCheck(reason: .manual) }
            }
        }

        let maxConcurrent = await pipeline.maxConcurrent
        let callCount = await pipeline.callCount

        XCTAssertLessThanOrEqual(
            maxConcurrent,
            1,
            "Concurrent runCheck calls must never overlap — only one pass in flight"
        )
        XCTAssertEqual(
            callCount,
            1,
            "All but the first concurrent caller should bail on the isChecking guard"
        )
    }

    func testRepeatedManualChecksDoNotBusyLoop() async {
        // A series of manual checks over time must each run once and finish,
        // never spinning or piling up.
        for _ in 0..<5 {
            await scheduler.runCheck(reason: .manual)
        }
        let callCount = await pipeline.callCount
        XCTAssertEqual(callCount, 5, "Each explicit check should run exactly once")
        let maxConcurrent = await pipeline.maxConcurrent
        XCTAssertLessThanOrEqual(maxConcurrent, 1)
    }
}
