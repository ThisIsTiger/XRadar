// RSSHubRequestBuilder.swift
// RSSHub 路由构造（DESIGN-RSSHUB.md §5.1）
import Foundation

/// 构造 RSSHub Twitter 用户路由 URL。必须使用 URLComponents，禁止字符串拼接。
public struct RSSHubRequestBuilder: Sendable {
    public init() {}

    public func makeURL(
        baseURL: String,
        handle: String,
        includeReplies: Bool,
        includeReposts: Bool,
        maximumCount: Int
    ) throws -> URL {
        guard var components = URLComponents(string: baseURL),
              let host = components.host, !host.isEmpty,
              !XHostPolicy.isXHost(host),
              components.user == nil, components.password == nil,
              components.fragment == nil, components.query == nil,
              components.scheme == "https"
                  || host == "localhost"
                  || host == "127.0.0.1"
                  || host == "[::1]"
                  || host == "::1" else {
            throw SourceError.invalidInstanceURL
        }

        // handle 不做字符集强校验（X handle 本身不含连字符等，但 RSSHub 路由
        // 只要求路径段安全；编码由 URLComponents 完成）。
        let normalizedHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !normalizedHandle.isEmpty else {
            throw SourceError.invalidInstanceURL
        }

        let count = min(max(1, maximumCount), 10)
        components.path = "/twitter/user/\(normalizedHandle)/includeReplies=\(includeReplies ? 1 : 0)&includeRts=\(includeReposts ? 1 : 0)&count=\(count)&showEmojiForRetweetAndReply=1&showSymbolForRetweetAndReply=0&showQuotedInTitle=0"

        guard let url = components.url else {
            throw SourceError.invalidInstanceURL
        }
        return url
    }
}
