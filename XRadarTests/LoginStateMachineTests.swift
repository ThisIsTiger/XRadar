// LoginStateMachineTests.swift
//
// Covers the login/session state machine: `XSessionState` helper properties and
// how `RuntimeState.status` derives a user-facing status from the last run
// summary (login required, action required, degraded, backing off, paused).
import XCTest
@testable import XRadarCore

final class LoginStateMachineTests: XCTestCase {
    func testSessionStateHelpers() {
        XCTAssertTrue(XSessionState.loggedIn(handle: "x").isLoggedIn)
        XCTAssertTrue(XSessionState.probablyLoggedIn.isLoggedIn)
        XCTAssertFalse(XSessionState.loggedOut.isLoggedIn)

        XCTAssertTrue(XSessionState.loggedIn(handle: "x").isPossiblyLoggedIn)
        XCTAssertFalse(XSessionState.loggedOut.isPossiblyLoggedIn)

        XCTAssertEqual(XSessionState.loggedOut.notLoggedInReason, "X 登录已失效，请重新登录")
        XCTAssertEqual(
            XSessionState.actionRequired(message: "验证").actionRequiredMessage,
            "验证"
        )
        XCTAssertEqual(
            XSessionState.actionRequired(message: "验证").notLoggedInReason,
            "需要处理: 验证"
        )
        XCTAssertEqual(
            XSessionState.failed(message: "boom").notLoggedInReason,
            "登录验证失败: boom"
        )
        XCTAssertEqual(
            XSessionState.validating.notLoggedInReason,
            "登录状态未知"
        )
    }

    func testRuntimeStateStatusTransitions() {
        var s = RuntimeState.default
        XCTAssertEqual(s.status, .idle(nextRunAt: nil))

        s.isPaused = true
        XCTAssertEqual(s.status, .paused)
        s.isPaused = false

        s.lastRunSummary = RunSummary(
            accountsChecked: 0, tweetsFound: 0, eventsGenerated: 0,
            loginRequired: true, actionRequired: nil, rateLimited: false,
            error: nil, isTransientError: false, finishedAt: Date()
        )
        XCTAssertEqual(s.status, .loginRequired)

        s.lastRunSummary = RunSummary(
            accountsChecked: 0, tweetsFound: 0, eventsGenerated: 0,
            loginRequired: false, actionRequired: "人机验证", rateLimited: false,
            error: nil, isTransientError: false, finishedAt: Date()
        )
        XCTAssertEqual(s.status, .actionRequired("人机验证"))

        s.lastRunSummary = RunSummary(
            accountsChecked: 0, tweetsFound: 0, eventsGenerated: 0,
            loginRequired: false, actionRequired: nil, rateLimited: false,
            error: "页面解析失败", isTransientError: false, finishedAt: Date()
        )
        XCTAssertEqual(s.status, .degraded("页面解析失败"))

        s.lastRunSummary = nil
        s.backoffUntil = Date().addingTimeInterval(30)
        if case .backingOff = s.status {
            // expected
        } else {
            XCTFail("Expected .backingOff when backoffUntil is in the future")
        }
    }
}
