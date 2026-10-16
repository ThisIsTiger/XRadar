// RuleEngine.swift
import Foundation

public actor RuleEngine {
    private let matcher: KeywordMatcher

    public init(matcher: KeywordMatcher = KeywordMatcher()) {
        self.matcher = matcher
    }

    public func evaluate(tweet: Tweet, against rules: [MonitorRule]) -> [RuleMatch] {
        rules.compactMap { rule in
            matcher.evaluate(tweet: tweet, rule: rule)
        }
    }

    public nonisolated func aggregateMatches(
        tweet: Tweet,
        matches: [RuleMatch],
        allRules: [MonitorRule]
    ) -> NotificationEvent? {
        guard !matches.isEmpty else { return nil }

        // Get all matched rules
        let matchedRules = allRules.filter { rule in
            matches.contains { $0.ruleID == rule.id }
        }

        // Aggregate rule IDs
        let matchedRuleIDs = matches.map { $0.ruleID }

        // Aggregate keywords (deduplicated)
        let allKeywords = matches.flatMap { $0.matchedKeywords }
        let uniqueKeywords = Array(Set(allKeywords))

        // Aggregate notification channels
        var allChannels: Set<NotificationChannelID> = []
        for rule in matchedRules {
            allChannels.formUnion(rule.notificationChannels)
        }

        // Build title from matched rule names (e.g. "今天 Tibo 要重置吗？")
        let ruleNames = matchedRules.map(\.name).joined(separator: "、")
        let title = ruleNames.isEmpty ? "@\(tweet.authorHandle)" : ruleNames

        // Build body
        var bodyParts: [String] = []
        if !uniqueKeywords.isEmpty {
            let keywordsText = uniqueKeywords.joined(separator: "、")
            bodyParts.append("命中：\(keywordsText)")
        }

        // Add tweet text (truncated)
        let tweetText = tweet.text.isEmpty ? "发布了一条媒体推文" : tweet.text
        let truncatedText = String(tweetText.prefix(220))
        bodyParts.append(truncatedText)

        let body = bodyParts.joined(separator: "｜")

        return NotificationEvent(
            id: "tweet:\(tweet.id)",
            tweetID: tweet.id,
            authorHandle: tweet.authorHandle,
            title: title,
            body: body,
            tweetURL: tweet.url,
            matchedRuleIDs: matchedRuleIDs,
            matchedKeywords: uniqueKeywords
        )
    }
}
