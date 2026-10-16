// KeywordMatcher.swift
import Foundation

public protocol RuleEvaluating: Sendable {
    func evaluate(tweet: Tweet, rule: MonitorRule) -> RuleMatch?
}

public struct RuleMatch: Equatable, Sendable {
    public let ruleID: UUID
    public let matchedKeywords: [String]
    public let reason: MatchReason
}

public enum MatchReason: Equatable, Sendable {
    case allNewTweets
    case keywordAny
    case keywordAll
}

public struct KeywordMatcher: RuleEvaluating {
    public init() {}

    public func evaluate(tweet: Tweet, rule: MonitorRule) -> RuleMatch? {
        // Check if rule is enabled
        guard rule.enabled else { return nil }

        // Check account match. RSS 源规则（§13）按 feedURL 分组抓取，
        // accountHandle 只是显示名，作者归属由 feed 自身决定，不参与匹配。
        if rule.feedURL == nil {
            guard tweet.authorHandle.lowercased() == rule.accountHandle.lowercased() else {
                return nil
            }
        }

        // Check tweet type filters
        switch tweet.kind {
        case .reply where !rule.includeReplies:
            return nil
        case .repost where !rule.includeReposts:
            return nil
        default:
            break
        }

        let normalizedTweetText = KeywordNormalizer.normalize(tweet.text, caseSensitive: rule.caseSensitive)

        // Check exclude keywords first
        for keyword in rule.excludeKeywords {
            let normalizedKeyword = KeywordNormalizer.normalize(keyword, caseSensitive: rule.caseSensitive)
            if Self.containsKeyword(normalizedTweetText, normalizedKeyword) {
                return nil // Excluded
            }
        }

        // Evaluate trigger mode
        switch rule.triggerMode {
        case .allNewTweets:
            return RuleMatch(
                ruleID: rule.id,
                matchedKeywords: [],
                reason: .allNewTweets
            )

        case .keywords:
            guard !rule.includeKeywords.isEmpty else { return nil }

            var matchedKeywords: [String] = []

            for keyword in rule.includeKeywords {
                let normalizedKeyword = KeywordNormalizer.normalize(keyword, caseSensitive: rule.caseSensitive)
                if Self.containsKeyword(normalizedTweetText, normalizedKeyword) {
                    matchedKeywords.append(keyword) // Return original keyword, not normalized
                }
            }

            switch rule.keywordMatchMode {
            case .any:
                if !matchedKeywords.isEmpty {
                    return RuleMatch(
                        ruleID: rule.id,
                        matchedKeywords: matchedKeywords,
                        reason: .keywordAny
                    )
                }

            case .all:
                if matchedKeywords.count == rule.includeKeywords.count {
                    return RuleMatch(
                        ruleID: rule.id,
                        matchedKeywords: matchedKeywords,
                        reason: .keywordAll
                    )
                }
            }

            return nil
        }
    }

    // MARK: - 关键词命中判定

    /// 纯拉丁字母/数字的关键词使用左词边界：命中位置的起始字符不能是字母/数字，
    /// 避免 "AI" 子串误中 "remain"；同时保留前缀延展（"Swift" 命中 "SwiftUI"）。
    /// 含 CJK 或符号的关键词保持子串语义。
    static func containsKeyword(_ text: String, _ keyword: String) -> Bool {
        guard !keyword.isEmpty else { return false }
        let keywordScalars = Array(keyword.unicodeScalars)
        guard keywordScalars.allSatisfy(Self.isAsciiAlphanumeric) else {
            return text.contains(keyword)
        }

        let textScalars = Array(text.unicodeScalars)
        if keywordScalars.count > textScalars.count { return false }

        var offset = 0
        let limit = textScalars.count - keywordScalars.count
        while offset <= limit {
            var matched = true
            for (delta, ks) in keywordScalars.enumerated() where textScalars[offset + delta] != ks {
                matched = false
                break
            }
            if matched {
                let startOK = offset == 0 || !Self.isAsciiAlphanumeric(textScalars[offset - 1])
                if startOK { return true }
            }
            offset += 1
        }
        return false
    }

    private static func isAsciiAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}
