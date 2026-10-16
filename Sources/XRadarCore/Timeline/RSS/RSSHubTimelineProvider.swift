// RSSHubTimelineProvider.swift
// 单个 RSSHub 实例的抓取（DESIGN-RSSHUB.md §6.1）
import Foundation

/// 针对单个 RSSHub 实例抓取并解析。空 Feed 状态由 Router 依据
/// `rawItemCount` 与 Cursor 判定（§6.1），本 Provider 不擅自抛错。
public struct RSSHubTimelineProvider: TimelineProvider, @unchecked Sendable {
    public let id: TimelineProviderID = .rssHub
    public let instanceURL: String
    public let instanceHost: String?
    private let builder: RSSHubRequestBuilder
    private let client: RSSHubHTTPClient

    public init(instanceURL: String, client: RSSHubHTTPClient? = nil) {
        self.instanceURL = instanceURL
        self.instanceHost = URL(string: instanceURL)?.host
        self.builder = RSSHubRequestBuilder()
        self.client = client ?? RSSHubHTTPClient(
            expectedHosts: URL(string: instanceURL).map { [$0.host ?? ""] } ?? []
        )
    }

    public func fetch(_ request: TimelineRequest) async throws -> TimelineFetchResult {
        let url = try builder.makeURL(
            baseURL: instanceURL,
            handle: request.accountHandle,
            includeReplies: request.includeReplies,
            includeReposts: request.includeReposts,
            maximumCount: request.maximumCount
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.timeoutInterval = RSSHubHTTPClient.timeoutInterval
        // 条件请求（§5.2）：按 provider + 实例身份取回上次保存的 validator。
        let validatorKey = HTTPValidator.sourceKey(
            provider: .rssHub,
            identity: instanceHost ?? instanceURL
        )
        if let saved = request.httpValidators[validatorKey] {
            if let eTag = saved.eTag {
                urlRequest.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            } else if let lastModified = saved.lastModified {
                urlRequest.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }

        let http = try await client.get(request: urlRequest)
        let validator = HTTPValidator(eTag: http.eTag, lastModified: http.lastModified)
        if http.notModified {
            return TimelineFetchResult(
                tweets: [],
                providerID: .rssHub,
                instanceHost: instanceHost,
                rawItemCount: 0,
                feedState: .notModified,
                httpValidator: validator
            )
        }

        let result = try XRSSParser.parse(
            data: http.body,
            requestHandle: request.accountHandle,
            maximumCount: request.maximumCount,
            excludedTweetIDs: request.excludedTweetIDs,
            now: Date()
        )

        return TimelineFetchResult(
            tweets: result.tweets,
            providerID: .rssHub,
            instanceHost: instanceHost,
            rawItemCount: result.rawItemCount,
            feedState: .healthy,
            httpValidator: validator
        )
    }
}