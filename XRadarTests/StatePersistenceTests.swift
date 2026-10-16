// StatePersistenceTests.swift
//
// Verifies JSON persistence is atomic and resilient: a round-trip preserves
// cursors, a corrupt main file recovers from the `.bak` backup, and a corrupt
// file with no backup yields nil (the caller falls back to `.default`). Also
// confirms the scheduler persists cursors so dedup survives a real restart.
import Foundation
import XCTest
@testable import XRadarCore

@MainActor
final class StatePersistenceTests: XCTestCase {
    var tempDir: URL!
    var store: JSONFileStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = JSONFileStore(baseDirectory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWriteThenReadRoundTrip() async throws {
        var state = RuntimeState.default
        state.isPaused = true
        state.accounts = [
            "alice": AccountCursor(
                seenTweetIDs: ["1", "2", "3"],
                initialized: true,
                lastCheckedAt: Date(),
                lastSuccessfulFetchAt: Date(),
                lastErrorCode: nil
            )
        ]

        try await store.write(state, to: "state.json")
        let read = await store.read(RuntimeState.self, from: "state.json")

        XCTAssertNotNil(read)
        XCTAssertEqual(read?.isPaused, true)
        XCTAssertEqual(read?.accounts["alice"]?.seenTweetIDs, ["1", "2", "3"])
        XCTAssertTrue(read?.accounts["alice"]?.initialized ?? false)
    }

    func testCorruptMainFileFallsBackToBackup() async throws {
        // Write twice: the first write lands in `state.json`, the second rotates
        // it into `state.json.bak` (a single write produces no backup).
        try await store.write(RuntimeState.default, to: "state.json")
        var state = RuntimeState.default
        state.isPaused = true
        try await store.write(state, to: "state.json")
        let _ = try "this is not json {{{".write(
            to: tempDir.appendingPathComponent("state.json"), atomically: true, encoding: .utf8
        )

        // The `.bak` still holds the previous good version, so recovery succeeds.
        let read = await store.read(RuntimeState.self, from: "state.json")
        XCTAssertNotNil(read, "Should recover from the .bak backup when the main file is corrupt")
    }

    func testCorruptWithNoBackupReturnsNil() async throws {
        let url = tempDir.appendingPathComponent("state.json")
        let _ = try "garbage".write(to: url, atomically: true, encoding: .utf8)

        let read = await store.read(RuntimeState.self, from: "state.json")
        XCTAssertNil(read, "No valid file and no backup should yield nil (caller uses .default)")
    }

    func testSchedulerPersistsCursors() async throws {
        let pipeline = MockMonitoringPipeline()
        let repo = StateRepository(store: store)
        let configRepo = ConfigurationRepository(store: store)
        // 源配置未完成时 Scheduler 禁止检查（约束 11），先写一份已完成配置。
        var config = AppConfiguration.default
        config.xSourceSettings = XSourceSettings(
            policy: .xWebOnly, rssHubInstances: [],
            webFallbackRiskAcknowledged: false, sourceSetupCompleted: true
        )
        try await store.write(config, to: "config.json")
        let scheduler = PollScheduler(
            pipeline: pipeline,
            stateRepository: repo,
            configRepository: configRepo
        )

        // First run returns a cursor for "bob".
        await pipeline.setNextSummary(
            PollRunSummary(
                startTime: Date(),
                endTime: Date(),
                accountsChecked: 1,
                tweetsFound: 2,
                eventsGenerated: 0,
                loginRequired: false,
                actionRequired: nil,
                rateLimited: false,
                error: nil,
                isTransientError: false,
                accountCursors: [
                    "bob": AccountCursor(
                        seenTweetIDs: ["a", "b"],
                        initialized: true,
                        lastCheckedAt: Date(),
                        lastSuccessfulFetchAt: Date(),
                        lastErrorCode: nil
                    )
                ]
            )
        )

        await scheduler.runCheck(reason: .manual)

        // The persisted state must contain bob's cursor.
        let state = await repo.load()
        XCTAssertEqual(state.accounts["bob"]?.seenTweetIDs, ["a", "b"])

        // A second run hands that cursor back to the pipeline.
        await scheduler.runCheck(reason: .manual)
        let handedBack = await pipeline.lastCursors
        XCTAssertEqual(
            handedBack["bob"]?.seenTweetIDs,
            ["a", "b"],
            "Persisted cursor must be handed back to the pipeline on the next run"
        )
    }
}
