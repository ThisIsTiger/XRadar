// UIHelpersMirrorTests.swift
// 镜像 XRadarVerifier 的 checkRecordRuleMatching / checkMonitorRuleReadiness。
import XCTest
@testable import XRadarCore

final class UIHelpersMirrorTests: XCTestCase {
    // MARK: - FetchRecord.belongsTo / accountDisplayName

    func testRecordBelongsToFeedRuleByURL() {
        let rule = MonitorRule(name: "GitHub Blog", accountHandle: "github.blog", feedURL: "https://github.blog/feed/")
        let record = FetchRecord(accountHandle: "https://github.blog/feed/", outcome: .matched, message: "x")
        XCTAssertTrue(record.belongsTo(rule: rule))
        let xRule = MonitorRule(name: "Elon", accountHandle: "elonmusk")
        XCTAssertFalse(record.belongsTo(rule: xRule))
    }

    func testRecordBelongsToCaseInsensitive() {
        let rule = MonitorRule(name: "B", accountHandle: "b", feedURL: "https://github.blog/feed/")
        let record = FetchRecord(accountHandle: "HTTPS://GitHub.Blog/feed/", outcome: .noNewTweets, message: "x")
        XCTAssertTrue(record.belongsTo(rule: rule))
    }

    func testRecordBelongsToXRuleByHandle() {
        let rule = MonitorRule(name: "Elon", accountHandle: "elonmusk")
        let record = FetchRecord(accountHandle: "ElonMusk", outcome: .notMatched, message: "x")
        XCTAssertTrue(record.belongsTo(rule: rule))
    }

    func testAccountDisplayNameHostifiesURL() {
        XCTAssertEqual(FetchRecordDisplay.name(for: "https://news.example/items/"), "news.example")
        let record = FetchRecord(accountHandle: "https://github.blog/feed/", outcome: .matched, message: "x")
        XCTAssertEqual(record.accountDisplayName, "github.blog")
    }

    func testAccountDisplayNameKeepsPlainHandle() {
        let record = FetchRecord(accountHandle: "ElonMusk", outcome: .notMatched, message: "x")
        XCTAssertEqual(record.accountDisplayName, "ElonMusk")
    }

    // MARK: - MonitorRule.isConfigured

    func testIsConfiguredRequiresHandle() {
        XCTAssertFalse(MonitorRule(name: "x", accountHandle: "").isConfigured)
    }

    func testIsConfiguredKeywordsModeRequiresKeywords() {
        XCTAssertFalse(MonitorRule(name: "x", accountHandle: "elonmusk").isConfigured)
        XCTAssertTrue(MonitorRule(name: "x", accountHandle: "elonmusk", includeKeywords: ["ai"]).isConfigured)
    }

    func testIsConfiguredAllTweetsModeNeedsNoKeywords() {
        XCTAssertTrue(MonitorRule(name: "x", accountHandle: "elonmusk", triggerMode: .allNewTweets).isConfigured)
    }

    func testIsConfiguredRejectsInvalidFeedURLs() {
        let bad = ["notaurl", "/relative/path", "ftp://example.com/rss",
                   "https://x.com/user/feed", "http://twitter.com/feed"]
        for url in bad {
            XCTAssertFalse(
                MonitorRule(name: "f", accountHandle: "site", feedURL: url, includeKeywords: ["ai"]).isConfigured,
                "feed 地址 \(url) 不应通过"
            )
        }
    }

    func testIsConfiguredAcceptsValidFeedURLs() {
        let good = ["https://github.blog/feed/", "http://localhost:1200/feed.xml"]
        for url in good {
            XCTAssertTrue(
                MonitorRule(name: "f", accountHandle: "site", feedURL: url, includeKeywords: ["ai"]).isConfigured,
                "feed 地址 \(url) 应通过"
            )
        }
    }

    func testIsConfiguredFeedKeywordsModeRequiresKeywords() {
        XCTAssertFalse(MonitorRule(name: "f", accountHandle: "site", feedURL: "https://github.blog/feed/").isConfigured)
        XCTAssertTrue(MonitorRule(name: "f", accountHandle: "site", feedURL: "https://github.blog/feed/", triggerMode: .allNewTweets).isConfigured)
    }
}
