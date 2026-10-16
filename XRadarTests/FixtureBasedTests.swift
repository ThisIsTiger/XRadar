// FixtureBasedTests.swift
//
// HTML Fixture tests for tweet extraction covering various X scenarios.
import Foundation
import XCTest
import WebKit
@testable import XRadarCore

@MainActor
final class FixtureBasedTests: XCTestCase {

    // MARK: - Helper

    func loadFixture(named name: String) async throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"),
              let html = try? String(contentsOf: url, encoding: .utf8) else {
            throw NSError(domain: "FixtureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture \(name) not found"])
        }
        return html
    }

    func extractTweets(from html: String) async throws -> [RawTweetDOMRecord] {
        // WebKit must be driven on the main actor. Creating the web view in
        // `setUp()` does not work: `setUp()` is nonisolated (it overrides a
        // nonisolated superclass method), so the object would be built outside
        // the actor. Build it here instead.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)

        // Inject the extraction script into the HTML (mirrors production, which
        // injects the same script before reading the DOM).
        let fullHTML = html.replacingOccurrences(of: "</body>", with: "<script>\(XDOMSelectors.tweetExtractionScript(maxTweets: 50))</script></body>")

        // A fresh WKWebView already reports `document.readyState == "complete"`
        // for its initial `about:blank` document, so readyState cannot signal
        // that OUR document committed. Load with a base URL and wait for the
        // document URL to change instead.
        let baseURL = URL(string: "https://x.com/testuser")
        _ = webView.loadHTMLString(fullHTML, baseURL: baseURL)

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let href = try? await webView.evaluateJavaScript("document.location.href")
            if let href = href as? String, href.hasPrefix("https://x.com/") { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let result = try? await webView.evaluateJavaScript(XDOMSelectors.tweetExtractionScript(maxTweets: 50))
        guard let jsonString = result as? String,
              let data = jsonString.data(using: .utf8),
              let records = try? JSONDecoder().decode([RawTweetDOMRecord].self, from: data) else {
            return []
        }
        return records
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
            XCTAssertTrue(first.text.contains("shipped"))
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
        // X renders the reply line as `data-testid="reply"` (social context, by
        // contrast, means a repost/quote), which is what the extractor reads.
        let html = """
        <article data-testid="tweet">
            <div data-testid="reply">Replying to @elonmusk</div>
            <div data-testid="tweetText">Thanks!</div>
            <a href="/testuser/status/123"><time datetime="2026-07-22T10:00:00Z"></time></a>
        </article>
        """

        let records = try await extractTweets(from: html)

        let reply = try XCTUnwrap(records.first)
        XCTAssertEqual(reply.replyingToText, "Replying to @elonmusk")
        XCTAssertEqual(reply.toTweet()?.kind, .reply)
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

        let pinned = try XCTUnwrap(records.first)
        XCTAssertTrue(pinned.isPinned)
    }
}