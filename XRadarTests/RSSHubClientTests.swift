// RSSHubClientTests.swift
// TASK-04: RSSHub 路由、HTTP 与实例健康（DESIGN-RSSHUB.md §5.1、§5.2、§7.2、§12.3）
import XCTest
@testable import XRadarCore

private final class RSSHubMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = RSSHubMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "Mock", code: -1))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

final class RSSHubClientTests: XCTestCase {
    private func makeSnowflakeID(at date: Date) -> UInt64 {
        let epochMs: UInt64 = 1288834974657
        let ms = UInt64(date.timeIntervalSince1970 * 1000)
        return ms >= epochMs ? (ms - epochMs) << 22 : 0
    }

    private func makeClient(expectedHosts: Set<String> = []) -> RSSHubHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RSSHubMockURLProtocol.self]
        return RSSHubHTTPClient(sessionConfiguration: config, expectedHosts: expectedHosts)
    }

    func testRouteMapping() throws {
        let builder = RSSHubRequestBuilder()
        let url = try builder.makeURL(
            baseURL: "https://rsshub.app",
            handle: "elonmusk",
            includeReplies: true,
            includeReposts: false,
            maximumCount: 10
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/twitter/user/elonmusk/includeReplies=1&includeRts=0&count=10&showEmojiForRetweetAndReply=1&showSymbolForRetweetAndReply=0&showQuotedInTitle=0")
    }

    func testInvalidInstanceRejected() {
        let builder = RSSHubRequestBuilder()
        XCTAssertThrowsError(
            try builder.makeURL(baseURL: "http://insecure.example.com", handle: "alice", includeReplies: false, includeReposts: false, maximumCount: 10)
        ) { error in
            XCTAssertEqual(error as? SourceError, .invalidInstanceURL)
        }
    }

    func testHTTP304MapsToNotModified() async throws {
        RSSHubMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: nil, headerFields: ["ETag": "\"x\""])!
            return (response, Data())
        }
        let result = try await makeClient().get(request: URLRequest(url: URL(string: "https://rsshub.app/x")!))
        XCTAssertTrue(result.notModified)
        XCTAssertEqual(result.eTag, "\"x\"")
    }

    func testHTTP429ReadsRetryAfter() async {
        RSSHubMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "900"])!
            return (response, Data())
        }
        do {
            _ = try await makeClient().get(request: URLRequest(url: URL(string: "https://rsshub.app/x")!))
            XCTFail("429 未抛错")
        } catch SourceError.rateLimited(_, let retryAfter) {
            XCTAssertNotNil(retryAfter)
        } catch {
            XCTFail("429 错误类型不符: \(error)")
        }
    }

    func testSelfHostedLocalhostAllowed() throws {
        let builder = RSSHubRequestBuilder()
        let url = try builder.makeURL(baseURL: "http://localhost:1200", handle: "alice", includeReplies: false, includeReposts: false, maximumCount: 10)
        XCTAssertTrue(url.absoluteString.hasPrefix("http://localhost:1200/twitter/user/alice/"))
    }
}