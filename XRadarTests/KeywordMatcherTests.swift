// KeywordMatcherTests.swift
import XCTest
@testable import XRadarCore

final class KeywordMatcherTests: XCTestCase {
    let matcher = KeywordMatcher()

    func createRule(
        includeKeywords: [String] = [],
        excludeKeywords: [String] = [],
        matchMode: KeywordMatchMode = .any,
        caseSensitive: Bool = false,
        includeReplies: Bool = false,
        includeReposts: Bool = false,
        triggerMode: TriggerMode = .keywords
    ) -> MonitorRule {
        MonitorRule(
            name: "Test Rule",
            accountHandle: "test",
            enabled: true,
            triggerMode: triggerMode,
            includeKeywords: includeKeywords,
            excludeKeywords: excludeKeywords,
            keywordMatchMode: matchMode,
            caseSensitive: caseSensitive,
            includeReplies: includeReplies,
            includeReposts: includeReposts
        )
    }

    func testBasicMatch() {
        let rule = createRule(includeKeywords: ["Starship"])
        let tweet = Tweet(
            id: "1",
            authorHandle: "test",
            text: "Starship launch tomorrow",
            url: URL(string: "https://x.com/test/status/1")!
        )

        let match = matcher.evaluate(tweet: tweet, rule: rule)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.matchedKeywords, ["Starship"])
    }

    func testCaseInsensitive() {
        let rule = createRule(includeKeywords: ["starship"], caseSensitive: false)
        let tweet = Tweet(
            id: "1",
            authorHandle: "test",
            text: "STARSHIP Launch",
            url: URL(string: "https://x.com/test/status/1")!
        )

        let match = matcher.evaluate(tweet: tweet, rule: rule)
        XCTAssertNotNil(match)
    }

    func testCaseSensitive() {
        let rule = createRule(includeKeywords: ["Starship"], caseSensitive: true)
        let tweet = Tweet(
            id: "1",
            authorHandle: "test",
            text: "starship launch",
            url: URL(string: "https://x.com/test/status/1")!
        )

        let match = matcher.evaluate(tweet: tweet, rule: rule)
        XCTAssertNil(match)
    }

    func testAnyMatchMode() {
        let rule = createRule(
            includeKeywords: ["Starship", "Mars"],
            matchMode: .any
        )

        let tweet1 = Tweet(
            id: "1",
            authorHandle: "test",
            text: "Starship is ready",
            url: URL(string: "https://x.com/test/status/1")!
        )
        let tweet2 = Tweet(
            id: "2",
            authorHandle: "test",
            text: "Mars mission planned",
            url: URL(string: "https://x.com/test/status/2")!
        )
        let tweet3 = Tweet(
            id: "3",
            authorHandle: "test",
            text: "Tesla earnings today",
            url: URL(string: "https://x.com/test/status/3")!
        )

        XCTAssertNotNil(matcher.evaluate(tweet: tweet1, rule: rule))
        XCTAssertNotNil(matcher.evaluate(tweet: tweet2, rule: rule))
        XCTAssertNil(matcher.evaluate(tweet: tweet3, rule: rule))
    }

    func testAllMatchMode() {
        let rule = createRule(
            includeKeywords: ["Starship", "Mars"],
            matchMode: .all
        )

        let tweet1 = Tweet(
            id: "1",
            authorHandle: "test",
            text: "Starship to Mars",
            url: URL(string: "https://x.com/test/status/1")!
        )
        let tweet2 = Tweet(
            id: "2",
            authorHandle: "test",
            text: "Starship is ready",
            url: URL(string: "https://x.com/test/status/2")!
        )

        XCTAssertNotNil(matcher.evaluate(tweet: tweet1, rule: rule))
        XCTAssertNil(matcher.evaluate(tweet: tweet2, rule: rule))
    }

    func testExclusionPriority() {
        let rule = createRule(
            includeKeywords: ["Starship"],
            excludeKeywords: ["delay"]
        )

        let tweet1 = Tweet(
            id: "1",
            authorHandle: "test",
            text: "Starship launch tomorrow",
            url: URL(string: "https://x.com/test/status/1")!
        )
        let tweet2 = Tweet(
            id: "2",
            authorHandle: "test",
            text: "Starship delay announced",
            url: URL(string: "https://x.com/test/status/2")!
        )

        XCTAssertNotNil(matcher.evaluate(tweet: tweet1, rule: rule))
        XCTAssertNil(matcher.evaluate(tweet: tweet2, rule: rule))
    }

    func testDisabledRule() {
        var rule = createRule(includeKeywords: ["Starship"])
        rule.enabled = false

        let tweet = Tweet(
            id: "1",
            authorHandle: "test",
            text: "Starship launch",
            url: URL(string: "https://x.com/test/status/1")!
        )

        XCTAssertNil(matcher.evaluate(tweet: tweet, rule: rule))
    }

    func testWrongAccount() {
        let rule = createRule(includeKeywords: ["Starship"])
        let tweet = Tweet(
            id: "1",
            authorHandle: "wrongaccount",
            text: "Starship launch",
            url: URL(string: "https://x.com/wrongaccount/status/1")!
        )

        XCTAssertNil(matcher.evaluate(tweet: tweet, rule: rule))
    }

    func testEmptyTweetText() {
        let rule = createRule(includeKeywords: ["Starship"])
        let tweet = Tweet(
            id: "1",
            authorHandle: "test",
            text: "",
            url: URL(string: "https://x.com/test/status/1")!
        )

        XCTAssertNil(matcher.evaluate(tweet: tweet, rule: rule))
    }

    func testChineseKeywords() {
        let rule = createRule(includeKeywords: ["火箭"])
        let tweet = Tweet(
            id: "1",
            authorHandle: "test",
            text: "火箭发射成功",
            url: URL(string: "https://x.com/test/status/1")!
        )

        let match = matcher.evaluate(tweet: tweet, rule: rule)
        XCTAssertNotNil(match)
    }

    func testPhraseMatching() {
        let rule = createRule(includeKeywords: ["Starship launch"])
        let tweet = Tweet(
            id: "1",
            authorHandle: "test",
            text: "The Starship launch was successful",
            url: URL(string: "https://x.com/test/status/1")!
        )

        let match = matcher.evaluate(tweet: tweet, rule: rule)
        XCTAssertNotNil(match)
    }

    // MARK: - 左词边界（拉丁关键词不误中包含它的单词）

    private func boundaryTweet(_ text: String) -> Tweet {
        Tweet(
            id: UUID().uuidString,
            authorHandle: "someone",
            text: text,
            url: URL(string: "https://example.com/x")!,
            publishedAt: Date(),
            kind: .original,
            isPinned: false
        )
    }

    private func feedRule(include: [String], exclude: [String] = []) -> MonitorRule {
        MonitorRule(
            name: "boundary",
            accountHandle: "site",
            feedURL: "https://example.com/feed",
            includeKeywords: include,
            excludeKeywords: exclude
        )
    }

    func testLatinShortKeywordDoesNotSubstringMatch() {
        let matcher = KeywordMatcher()
        XCTAssertNil(matcher.evaluate(tweet: boundaryTweet("线下活动｜Echoes Remain：唱片展"),
                                     rule: feedRule(include: ["AI"])))
        XCTAssertNil(matcher.evaluate(tweet: boundaryTweet("email 泛滥的一天"),
                                     rule: feedRule(include: ["mail"])))
    }

    func testLatinKeywordStillMatchesNormallyAndPrefixExtension() {
        let matcher = KeywordMatcher()
        let hit = matcher.evaluate(tweet: boundaryTweet("DeepSeek AI 模型发布"), rule: feedRule(include: ["AI"]))
        XCTAssertEqual(hit?.matchedKeywords, ["AI"])
        XCTAssertNotNil(matcher.evaluate(tweet: boundaryTweet("SwiftUI 教程合集"), rule: feedRule(include: ["Swift"])))
    }

    func testCJKKeywordsKeepSubstringSemantics() {
        let matcher = KeywordMatcher()
        XCTAssertNotNil(matcher.evaluate(tweet: boundaryTweet("苹果发布会预告"), rule: feedRule(include: ["苹果"])))
        XCTAssertNotNil(matcher.evaluate(tweet: boundaryTweet("iOS版已发布"), rule: feedRule(include: ["iOS"])))
    }

    func testExcludeKeywordsUseWordBoundaryToo() {
        let matcher = KeywordMatcher()
        XCTAssertNotNil(matcher.evaluate(tweet: boundaryTweet("Remain 展览模型"),
                                         rule: feedRule(include: ["模型"], exclude: ["ai"])))
        XCTAssertNil(matcher.evaluate(tweet: boundaryTweet("ai 模型速览"),
                                     rule: feedRule(include: ["模型"], exclude: ["ai"])))
    }
}
