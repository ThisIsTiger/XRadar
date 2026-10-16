// Tweet.swift
import Foundation

public struct Tweet: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let authorHandle: String
    public let text: String
    public let url: URL
    public let publishedAt: Date?
    public let kind: TweetKind
    public let isPinned: Bool

    public init(
        id: String,
        authorHandle: String,
        text: String,
        url: URL,
        publishedAt: Date? = nil,
        kind: TweetKind = .unknown,
        isPinned: Bool = false
    ) {
        self.id = id
        self.authorHandle = authorHandle
        self.text = text
        self.url = url
        self.publishedAt = publishedAt
        self.kind = kind
        self.isPinned = isPinned
    }
}

public enum TweetKind: String, Codable, Sendable {
    case original
    case reply
    case repost
    case unknown
}

// Raw DOM record from JavaScript extraction
struct RawTweetDOMRecord: Codable {
    let id: String
    let url: String
    let authorHandle: String
    let text: String
    let publishedAt: String?
    let isPinned: Bool
    let hasSocialContext: Bool
    let replyingToText: String?

    func toTweet() -> Tweet? {
        guard let url = URL(string: url) else { return nil }

        let kind: TweetKind
        if hasSocialContext, replyingToText != nil {
            // Social context present AND explicitly a "Replying to" line => reply.
            kind = .reply
        } else if hasSocialContext {
            // Social context without a reply line (e.g. "X reposted") => repost.
            kind = .repost
        } else {
            kind = .original
        }

        let date: Date?
        if let publishedAt = publishedAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: publishedAt) {
                date = parsed
            } else {
                // Fallback for non-fractional strings
                let fallback = ISO8601DateFormatter()
                date = fallback.date(from: publishedAt)
            }
        } else {
            date = nil
        }

        return Tweet(
            id: id,
            authorHandle: authorHandle,
            text: text,
            url: url,
            publishedAt: date,
            kind: kind,
            isPinned: isPinned
        )
    }
}
