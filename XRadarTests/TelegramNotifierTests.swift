// TelegramNotifierTests.swift
//
// Exercises Telegram delivery error handling without touching the real login
// keychain or the network. A `URLProtocol` mock returns configurable HTTP
// statuses / errors, and an in-memory `KeychainStoreProtocol` mock supplies
// (or withholds) credentials. Crucially, Telegram failures must surface as a
// `.failure` result and never crash — local macOS notifications are unaffected.
import Foundation
import XCTest
@testable import XRadarCore

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

actor MockKeychainStore: KeychainStoreProtocol {
    var token: String? = "fake_bot_token"
    var chatID: String? = "fake_chat_id"

    func loadTelegramBotToken() async throws -> String {
        guard let t = token else { throw KeychainError.itemNotFound }
        return t
    }

    func loadTelegramChatID() async throws -> String {
        guard let c = chatID else { throw KeychainError.itemNotFound }
        return c
    }

    func saveTelegramBotToken(_ token: String) async throws { self.token = token }
    func saveTelegramChatID(_ chatID: String) async throws { self.chatID = chatID }
    func deleteTelegramCredentials() async throws { token = nil; chatID = nil }
    func setToken(_ value: String?) { token = value }
}

final class TelegramNotifierTests: XCTestCase {
    var keychain: MockKeychainStore!

    override func setUp() {
        keychain = MockKeychainStore()
        MockURLProtocol.requestHandler = nil
    }

    private func makeSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MockURLProtocol.requestHandler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func sampleEvent() -> NotificationEvent {
        NotificationEvent(
            id: "1",
            tweetID: "1",
            authorHandle: "alice",
            title: "@alice",
            body: "Heads up: feature shipped",
            tweetURL: URL(string: "https://x.com/alice/status/1")!,
            matchedRuleIDs: [],
            matchedKeywords: ["feature"]
        )
    }

    func testSendSuccess() async {
        let session = makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let notifier = TelegramNotifier(keychainStore: keychain, session: session)
        let result = await notifier.send(sampleEvent())
        XCTAssertTrue(result.success, "Expected success, got \(result.errorMessage ?? "")")
    }

    func testSendBadRequest() async {
        let session = makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let notifier = TelegramNotifier(keychainStore: keychain, session: session)
        let result = await notifier.send(sampleEvent())
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorMessage, "Configuration error (HTTP 400)")
    }

    func testSendRateLimitedNoRetryAfter() async {
        let session = makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let notifier = TelegramNotifier(keychainStore: keychain, session: session)
        let result = await notifier.send(sampleEvent())
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorMessage, "Rate limited")
    }

    func testSendServerErrorRetriesThenSucceeds() async {
        var calls = 0
        let session = makeSession { req in
            calls += 1
            let code = calls == 1 ? 500 : 200
            let resp = HTTPURLResponse(url: req.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let notifier = TelegramNotifier(keychainStore: keychain, session: session)
        let result = await notifier.send(sampleEvent())
        XCTAssertTrue(result.success, "Retry on 5xx should eventually succeed: \(result.errorMessage ?? "")")
        XCTAssertEqual(calls, 2, "Should have retried once after the 500")
    }

    func testSendNetworkError() async {
        let session = makeSession { _ in
            throw URLError(.notConnectedToInternet)
        }
        let notifier = TelegramNotifier(keychainStore: keychain, session: session)
        let result = await notifier.send(sampleEvent())
        XCTAssertFalse(result.success)
        XCTAssertTrue(
            result.errorMessage?.hasPrefix("Network error") ?? false,
            "Expected network error, got \(result.errorMessage ?? "")"
        )
    }

    func testSendMissingCredentials() async {
        await keychain.setToken(nil)
        let session = makeSession { req in
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let notifier = TelegramNotifier(keychainStore: keychain, session: session)
        let result = await notifier.send(sampleEvent())
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.errorMessage, "Telegram credentials not configured")
    }
}
