// RSSDirectFeedProvider.swift
// 自定义 RSS 源的直连抓取（DESIGN-RSSHUB.md §13）。
// 复用无 Cookie 的 RSSHubHTTPClient 与通用解析：单 host 重定向白名单、
// 禁 X/Twitter 域名、5 MiB/10s 限制、ETag/304 支持。
import Foundation

public enum RSSDirectFeedError: Error, Equatable, Sendable {
    case invalidURL
    case disallowedHost
}

extension RSSDirectFeedError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "RSS 源地址无效，需要绝对 http(s) URL"
        case .disallowedHost:
            return "不能把 X/Twitter 链接当作 RSS 源，请改用账号规则"
        }
    }
}

public struct RSSDirectFeedResult: Sendable {
    public let tweets: [Tweet]
    public let rawItemCount: Int
    public let feedState: FeedState
    public let eTag: String?

    public init(tweets: [Tweet], rawItemCount: Int, feedState: FeedState, eTag: String?) {
        self.tweets = tweets
        self.rawItemCount = rawItemCount
        self.feedState = feedState
        self.eTag = eTag
    }
}

public protocol RSSDirectFeedProviding: Sendable {
    func fetch(
        rss url: URL,
        excludedIDs: Set<String>,
        maximumCount: Int,
        etag: String?
    ) async throws -> RSSDirectFeedResult
}

public struct RSSDirectFeedProvider: RSSDirectFeedProviding {
    private let clientFactory: @Sendable (URL) -> RSSHubHTTPClient

    public init(
        clientFactory: @escaping @Sendable (URL) -> RSSHubHTTPClient = { url in
            RSSHubHTTPClient(expectedHosts: url.host.map { [$0] } ?? [])
        }
    ) {
        self.clientFactory = clientFactory
    }

    /// URL 必须是绝对 http(s) 地址且不是 X/Twitter 域名。
    public static func isValidFeedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host?.lowercased(),
              !XHostPolicy.isXHost(host) else {
            return false
        }
        return true
    }

    public func fetch(
        rss url: URL,
        excludedIDs: Set<String>,
        maximumCount: Int,
        etag: String?
    ) async throws -> RSSDirectFeedResult {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw RSSDirectFeedError.invalidURL
        }
        if let host = url.host?.lowercased(), XHostPolicy.isXHost(host) {
            throw RSSDirectFeedError.disallowedHost
        }

        let client = clientFactory(url)
        var request = URLRequest(url: url)
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let http = try await client.get(request: request)
        if http.notModified {
            return RSSDirectFeedResult(tweets: [], rawItemCount: 0, feedState: .notModified, eTag: http.eTag)
        }
        let parsed = try XRSSParser.parseGeneric(
            data: http.body,
            defaultAuthor: url.host?.lowercased() ?? "feed",
            maximumCount: maximumCount,
            excludedTweetIDs: excludedIDs,
            now: Date()
        )
        return RSSDirectFeedResult(
            tweets: parsed.tweets,
            rawItemCount: parsed.rawItemCount,
            feedState: .healthy,
            eTag: http.eTag
        )
    }
}
