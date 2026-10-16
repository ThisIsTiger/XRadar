// MockFullChainTests.swift
//
// End-to-end-with-mocks: the scheduler drives the pipeline, persists the result
// to the repository, and the derived runtime status reflects login-required /
// rate-limited conditions. This is the "Mock 完整链路" acceptance check — no
// real X, WebKit, keychain, or network involved.
import Foundation
import XCTest
@testable import XRadarCore

@MainActor
final class MockFullChainTests: XCTestCase {
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

    func testLoginRequiredPropagatesToStatus() async {
        await pipeline.setNextSummary(
            PollRunSummary(
                startTime: Date(), endTime: Date(),
                accountsChecked: 1, tweetsFound: 0, eventsGenerated: 0,
                loginRequired: true, actionRequired: nil, rateLimited: false,
                error: "X 登录已失效，请重新登录",
                isTransientError: false,
                accountCursors: [:]
            )
        )

        await scheduler.runCheck(reason: .manual)

        let state = await repo.load()
        XCTAssertTrue(state.lastRunSummary?.loginRequired ?? false)
        XCTAssertEqual(state.status, .loginRequired)
    }

    func testRateLimitedSetsBackoffAndStatus() async {
        await pipeline.setNextSummary(
            PollRunSummary(
                startTime: Date(), endTime: Date(),
                accountsChecked: 1, tweetsFound: 0, eventsGenerated: 0,
                loginRequired: false, actionRequired: nil, rateLimited: true,
                error: nil, isTransientError: false, accountCursors: [:]
            )
        )

        await scheduler.runCheck(reason: .manual)

        let state = await repo.load()
        XCTAssertTrue(state.lastRunSummary?.rateLimited ?? false)
        XCTAssertNotNil(state.backoffUntil, "Rate limiting must record a backoff window")
    }

    func testActionRequiredPropagatesToStatus() async {
        await pipeline.setNextSummary(
            PollRunSummary(
                startTime: Date(), endTime: Date(),
                accountsChecked: 1, tweetsFound: 0, eventsGenerated: 0,
                loginRequired: false, actionRequired: "请完成人机验证", rateLimited: false,
                error: nil, isTransientError: false, accountCursors: [:]
            )
        )

        await scheduler.runCheck(reason: .manual)

        let state = await repo.load()
        XCTAssertEqual(state.status, .actionRequired("请完成人机验证"))
    }
}
