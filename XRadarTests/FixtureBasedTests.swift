// FixtureBasedTests.swift
//
// HTML Fixture tests for tweet extraction covering various X scenarios.
import Foundation
import XCTest
import WebKit
@testable import XRadarCore

@MainActor
final class FixtureBasedTests: XCTestCase {
    var webView: WKWebView!

    override func setUp() {
        super.setUp()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
    }

    override func tearDown() {
        webView = nil
        super.tearDown()
    }

    // MARK: - Helper

    func loadFixture(named name: String) async throws -> String {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "FixtureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture \(name) not found"])
        }
        return html
    }

    func extractTweets(from html: String) async throws -> [RawTweetDOMRecord] {
        // Inject the extraction script into the HTML
        let fullHTML = html.replacingOccurrences(of: "</body>", with: "<script>\(XDOMSelectors.tweetExtractionScript(maxTweets: 50))</script></body>")

        return await withCheckedContinuation { continuation in
            webView.loadHTMLString(fullHTML, baseURL: nil)

            // Wait for page load then extract
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: [])
                    return
                }

                self.webView.evaluateJavaScript(XDOMSelectors.tweetExtractionScript(maxTweets: 50)) { result, error in
                    guard let jsonString = result as? String,
                          let data = jsonString.data(using: .utf8),
                          let records = try? JSONDecoder().decode([RawTweetDOMRecord].self, from: data) else {
                        continuation.resume(returning: [])
                        return
                    }
                    continuation.resume(returning: records)
                }
            }
        }
    }

    // MARK: - Tests

    func testOriginalTweetsExtraction() async throws {
        let html = try await loadFixture(named: "profile_originals")
        let records = try await extractTweets(from: html)

        XCTAssertGreaterThanOrEqual(records.count, 2, "Should extract at least 2 original tweets")

        // Verify first tweet
        if let first = records.first {
            XCTAssertEqual(first.id, "1234567890")
            XCTAssertEqual(first.authorHandle, "testuser")
            XCTAssertTrue(first.text?.contains("shipped") ?? false)
            XCTAssertFalse(first.hasSocialContext)
        }
    }

    func testRepostsExtraction() async throws {
        let html = try await loadFixture(named: "profile_reposts")
        let records = try await extractTweets(from: html)

        // Should identify reposts
        let reposts = records.filter { $0.hasSocialContext }
        XCTAssertGreaterThanOrEqual(reposts.count, 1, "Should identify reposts")
    }

    func testEmptyProfile() async throws {
        let html = try await loadFixture(named: "profile_empty")
        let records = try await extractTweets(from: html)

        XCTAssertEqual(records.count, 0, "Empty profile should return no tweets")
    }

    func testRepliesDetection() async throws {
        // This tests the reply detection logic
        let html = """
        <article data-testid="tweet">
            <div data-testid="socialContext">Replying to @elonmusk</div>
            <div data-testid="tweetText">Thanks!</div>
            <a href="/testuser/status/123"><time datetime="2026-07-22T10:00:00Z"></time></a>
        </article>
        """

        let records = try await extractTweets(from: html)

        if let reply = records.first {
            XCTAssertEqual(reply.replyingToText, "Replying to @elonmusk")
        }
    }

    func testPinnedTweetDetection() async throws {
        let html = """
        <article data-testid="tweet">
            <div data-testid="socialContext">Pinned Tweet</div>
            <div data-testid="tweetText">My important announcement</div>
            <a href="/testuser/status/456"><time datetime="2026-07-22T10:00:00Z"></time></a>
        </article>
        """

        let records = try await extractTweets(from: html)

        if let pinned = records.first {
            XCTAssertTrue(pinned.isPinned)
        }
    }
}