// NotificationEvent.swift
import Foundation

public struct NotificationEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let tweetID: String
    public let authorHandle: String
    public let title: String
    public let body: String
    public let tweetURL: URL
    public let matchedRuleIDs: [UUID]
    public let matchedKeywords: [String]
    public let createdAt: Date
    public var readAt: Date?
    public var channelResults: [NotificationChannelID: DeliveryResult]

    public init(
        id: String,
        tweetID: String,
        authorHandle: String,
        title: String,
        body: String,
        tweetURL: URL,
        matchedRuleIDs: [UUID],
        matchedKeywords: [String],
        createdAt: Date = Date(),
        readAt: Date? = nil,
        channelResults: [NotificationChannelID: DeliveryResult] = [:]
    ) {
        self.id = id
        self.tweetID = tweetID
        self.authorHandle = authorHandle
        self.title = title
        self.body = body
        self.tweetURL = tweetURL
        self.matchedRuleIDs = matchedRuleIDs
        self.matchedKeywords = matchedKeywords
        self.createdAt = createdAt
        self.readAt = readAt
        self.channelResults = channelResults
    }
}

public struct DeliveryResult: Codable, Equatable, Sendable {
    public let success: Bool
    public let timestamp: Date
    public let errorMessage: String?

    public init(success: Bool, timestamp: Date = Date(), errorMessage: String? = nil) {
        self.success = success
        self.timestamp = timestamp
        self.errorMessage = errorMessage
    }

    public static let success = DeliveryResult(success: true)
    public static func failure(_ message: String) -> DeliveryResult {
        DeliveryResult(success: false, errorMessage: message)
    }
}
