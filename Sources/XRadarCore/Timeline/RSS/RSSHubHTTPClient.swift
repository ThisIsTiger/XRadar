// RSSHubHTTPClient.swift
// 无 Cookie 的 RSSHub HTTP 客户端（DESIGN-RSSHUB.md §5.2）
import Foundation

public struct RSSHubHTTPResult: Sendable {
    public let statusCode: Int
    public let body: Data
    public let eTag: String?
    public let lastModified: String?
    public let notModified: Bool
    public let finalURL: URL?

    public init(
        statusCode: Int,
        body: Data,
        eTag: String?,
        lastModified: String?,
        notModified: Bool,
        finalURL: URL?
    ) {
        self.statusCode = statusCode
        self.body = body
        self.eTag = eTag
        self.lastModified = lastModified
        self.notModified = notModified
        self.finalURL = finalURL
    }
}

/// 手工处理重定向，限制只跳转到原 host（DESIGN-RSSHUB.md §5.2）。
public final class StrictRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let expectedHosts: Set<String>
    private let disallowedHosts: Set<String> = ["x.com", "www.x.com", "twitter.com", "www.twitter.com"]

    public init(expectedHosts: Set<String>) {
        self.expectedHosts = Set(expectedHosts.map { $0.lowercased() })
    }

    func allows(_ host: String) -> Bool {
        self.expectedHosts.isEmpty || self.expectedHosts.contains(host.lowercased())
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let host = url.host?.lowercased(),
              expectedHosts.contains(host),
              !disallowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// 独立 ephemeral session、10 秒超时、5 MiB 响应上限、支持 ETag/304。
public struct RSSHubHTTPClient: Sendable {
    public static let maxResponseSize = 5 * 1024 * 1024
    public static let timeoutInterval: TimeInterval = 10

    private let session: URLSession
    private let delegate: StrictRedirectDelegate

    public init(sessionConfiguration: URLSessionConfiguration? = nil, expectedHosts: Set<String> = []) {
        let configuration = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = Self.timeoutInterval
        // 被动等待正文超时，由实现兜底
        configuration.timeoutIntervalForResource = 60

        let delegate = StrictRedirectDelegate(expectedHosts: expectedHosts)
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// 发起 GET 请求。返回 nil body 之外的所有结果；错误直接抛出。
    public func get(request: URLRequest) async throws -> RSSHubHTTPResult {
        var request = request
        guard let requestHost = request.url?.host?.lowercased(),
              !XHostPolicy.isXHost(requestHost),
              self.delegate.allows(requestHost) else {
            throw SourceError.redirectRejected
        }
        request.setValue(
            "application/atom+xml, application/rss+xml, application/xml, text/xml",
            forHTTPHeaderField: "Accept"
        )

        do {
            let (body, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let eTag = http.value(forHTTPHeaderField: "ETag")
                let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
                if http.statusCode == 304 {
                    return RSSHubHTTPResult(
                        statusCode: 304,
                        body: Data(),
                        eTag: eTag,
                        lastModified: lastModified,
                        notModified: true,
                        finalURL: http.url
                    )
                }
                // 重定向被 StrictRedirectDelegate 拒绝（跨 host 或跳往 x.com/twitter.com）：
                // URLSession 会把原始 3xx 响应交回，如实报告 .redirectRejected（§5.2、§12.3），
                // 而不是误报为"网络不可用"。
                if (301...308).contains(http.statusCode), http.statusCode != 306 {
                    throw SourceError.redirectRejected
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw Self.httpError(
                        statusCode: http.statusCode,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After")
                    )
                }
                guard body.count <= Self.maxResponseSize else {
                    throw SourceError.responseTooLarge
                }
                guard let finalHost = http.url?.host?.lowercased(),
                      !XHostPolicy.isXHost(finalHost),
                      self.delegate.allows(finalHost) else {
                    throw SourceError.redirectRejected
                }
                return RSSHubHTTPResult(
                    statusCode: http.statusCode,
                    body: body,
                    eTag: eTag,
                    lastModified: lastModified,
                    notModified: false,
                    finalURL: http.url
                )
            }
            throw SourceError.networkUnavailable(provider: .rssHub)
        } catch let sourceError as SourceError {
            throw sourceError
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost:
                throw SourceError.requestTimeout(provider: .rssHub)
            case .notConnectedToInternet, .internationalRoamingOff:
                throw SourceError.networkUnavailable(provider: .rssHub)
            default:
                throw SourceError.networkUnavailable(provider: .rssHub)
            }
        } catch {
            throw SourceError.networkUnavailable(provider: .rssHub)
        }
    }

    private static func httpError(statusCode: Int, retryAfter: String?) -> SourceError {
        let date: Date?
        if let retryAfter {
            if let seconds = Int(retryAfter) {
                date = Date().addingTimeInterval(TimeInterval(seconds))
            } else {
                date = HTTPDate().parse(retryAfter)
            }
        } else {
            date = nil
        }
        switch statusCode {
        case 404, 410:
            return .accountUnavailable(statusCode: statusCode)
        case 429:
            return .rateLimited(provider: .rssHub, retryAfter: date)
        case 400..<500:
            return .httpStatus(provider: .rssHub, statusCode: statusCode)
        default:
            // 5xx 等
            return .networkUnavailable(provider: .rssHub)
        }
    }

    private struct HTTPDate {
        func parse(_ rawValue: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: rawValue)
        }
    }
}
