// RSSParserTests.swift
// TASK-03: RSS/Atom Parser（DESIGN-RSSHUB.md §5.3–5.5、§12.2）
import XCTest
@testable import XRadarCore

final class RSSParserTests: XCTestCase {
    private func makeSnowflakeID(at date: Date) -> UInt64 {
        let epochMs: UInt64 = 1288834974657
        let ms = UInt64(date.timeIntervalSince1970 * 1000)
        return ms >= epochMs ? (ms - epochMs) << 22 : 0
    }

    func testRSS2MappingAndDedup() throws {
        let now = Date()
        let replyID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-60)))
        let dupID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-120)))

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0"><channel><title>Subject</title>
        <item>
          <title>↩️@someone 这是回复 &amp;<b>加粗</b></title>
          <link>https://x.com/agenttest/status/\(replyID)</link>
          <pubDate>Mon, 06 Jan 2025 10:00:00 +0000</pubDate>
          <author>显示名甲</author>
        </item>
        <item>
          <title>重复 ID 应被去重</title>
          <link>https://x.com/agenttest/status/\(dupID)</link>
          <pubDate>Tue, 07 Jan 2025 10:00:00 +0000</pubDate>
        </item>
        <item>
          <title>重复 ID 应被去重（第二份）</title>
          <link>https://x.com/agenttest/status/\(dupID)</link>
          <pubDate>Tue, 07 Jan 2025 10:00:00 +0000</pubDate>
        </item>
        <item>
          <title>无效状态 ID 必须丢弃</title>
          <link>https://x.com/agenttest/status/notanumber</link>
          <pubDate>Fri, 10 Jan 2025 10:00:00 +0000</pubDate>
        </item>
        </channel></rss>
        """
        let result = try XRSSParser.parse(
            data: Data(xml.utf8),
            requestHandle: "agenttest",
            maximumCount: 10,
            now: now
        )
        XCTAssertEqual(result.tweets.count, 2)
        XCTAssertEqual(result.rawItemCount, 3)

        let reply = try XCTUnwrap(result.tweets.first { $0.id == String(replyID) })
        XCTAssertEqual(reply.kind, .reply)
        XCTAssertEqual(reply.authorHandle, "agenttest")
        XCTAssertTrue(reply.text.contains("@someone"))
        XCTAssertFalse(reply.text.contains("↩️"))

        XCTAssertEqual(result.tweets.filter { $0.id == String(dupID) }.count, 1)
    }

    func testAtomMappingAndSnowflakePriority() throws {
        let now = Date()
        let firstID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-10)))

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Subject</title>
          <entry>
            <title>🔁@someone 引用转发的旧推</title>
            <id>tag:rsshub,2026:\(firstID)</id>
            <link href="https://twitter.com/agenttest/status/\(firstID)"/>
            <published>2020-01-01T00:00:00Z</published>
            <content type="html">&lt;p&gt;引用内容&lt;/p&gt;</content>
            <author><name>阿奇</name></author>
          </entry>
        </feed>
        """
        let result = try XRSSParser.parse(
            data: Data(xml.utf8),
            requestHandle: "agenttest",
            maximumCount: 10,
            now: now
        )
        XCTAssertEqual(result.tweets.count, 1)
        let tweet = try XCTUnwrap(result.tweets.first)
        XCTAssertEqual(tweet.kind, .repost)
        XCTAssertEqual(tweet.authorHandle, "agenttest")
        XCTAssertTrue(tweet.url.absoluteString.hasPrefix("https://x.com/agenttest/status/"))
        // Snowflake 时间优先于旧 RSS 日期
        let publishedAt = try XCTUnwrap(tweet.publishedAt)
        XCTAssertGreaterThan(publishedAt.timeIntervalSince(now), -3600)
    }

    func testMediaPlaceholderAndCDATA() throws {
        let now = Date()
        let mediaID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-180)))
        let placeholderID = UInt64(makeSnowflakeID(at: now.addingTimeInterval(-240)))

        let xml = """
        <rss version="2.0"><channel>
        <item>
          <title></title>
          <link>https://x.com/agenttest/status/\(mediaID)</link>
          <description><![CDATA[<p>&nbsp;转载自「测试」&nbsp;与 &amp;amp;兄弟</p>]]></description>
          <pubDate>Wed, 08 Jan 2025 10:00:00 +0000</pubDate>
        </item>
        <item>
          <title></title>
          <link>https://x.com/agenttest/status/\(placeholderID)</link>
          <pubDate>Wed, 08 Jan 2025 11:00:00 +0000</pubDate>
        </item>
        </channel></rss>
        """
        let result = try XRSSParser.parse(
            data: Data(xml.utf8),
            requestHandle: "agenttest",
            maximumCount: 10,
            now: now
        )
        let media = try XCTUnwrap(result.tweets.first { $0.id == String(mediaID) })
        XCTAssertTrue(media.text.contains("转载自「测试」"))
        XCTAssertFalse(media.text.contains("<"))
        let placeholder = try XCTUnwrap(result.tweets.first { $0.id == String(placeholderID) })
        XCTAssertEqual(placeholder.text, "发布了一条媒体推文")
    }

    func testNoExternalEntityLoading() throws {
        let now = Date()
        let xxe = """
        <?xml version="1.0"?>
        <!DOCTYPE feed [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
        <rss version="2.0"><channel><item>
          <title>&xxe;</title>
          <link>https://x.com/agenttest/status/12345</link>
          <pubDate>Mon, 06 Jan 2025 10:00:00 +0000</pubDate>
        </item></channel></rss>
        """
        // 外部实体不可加载：要么解析失败，要么内容不含外部文件内容
        do {
            let result = try XRSSParser.parse(
                data: Data(xxe.utf8),
                requestHandle: "agenttest",
                maximumCount: 10,
                now: now
            )
            let joined = result.tweets.map(\.text).joined()
            XCTAssertFalse(joined.contains("root:"))
            XCTAssertFalse(joined.contains("xxe"))
        } catch SourceError.invalidFeed {
            // 拒绝解析外部实体是合法的
        }
    }

    func testOversizeResponseRejected() {
        let big = Data(repeating: 0x3C, count: 5 * 1024 * 1024 + 1)
        XCTAssertThrowsError(
            try XRSSParser.parse(data: big, requestHandle: "agenttest", maximumCount: 10, now: Date()),
            "超大响应必须被拒绝"
        ) { error in
            XCTAssertEqual(error as? SourceError, .responseTooLarge)
        }
    }

    func testNoDateDiscarded() throws {
        let now = Date()
        let futureID = makeSnowflakeID(at: now.addingTimeInterval(600))
        let xml = """
        <rss version="2.0"><channel><item>
          <title>没有日期也没有有效 ID</title>
          <link>https://x.com/agenttest/status/\(futureID)</link>
        </item></channel></rss>
        """
        let result = try XRSSParser.parse(
            data: Data(xml.utf8),
            requestHandle: "agenttest",
            maximumCount: 10,
            now: now
        )
        XCTAssertTrue(result.tweets.isEmpty)
        XCTAssertEqual(result.rawItemCount, 0)
    }

    // MARK: - TASK-10: 自定义 RSS 源（DESIGN-RSSHUB.md §13）

    func testGenericMapping() throws {
        let now = Date()
        // 窗口内/外日期相对 now 生成（整秒），硬编码日历日期会随时间失效。
        func rfc822(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return f.string(from: date)
        }
        let recentDate = Date(timeIntervalSince1970: now.addingTimeInterval(-1 * 24 * 60 * 60).timeIntervalSince1970.rounded())
        let ancientDate = Date(timeIntervalSince1970: now.addingTimeInterval(-30 * 24 * 60 * 60).timeIntervalSince1970.rounded())
        let xml = """
        <rss version="2.0"><channel><title>Example News</title>
          <item>
            <title>Launch: <b>feature</b> ready</title>
            <link>https://news.example/items/1</link>
            <guid>https://news.example/items/1</guid>
            <pubDate>\(rfc822(recentDate))</pubDate>
            <author>newsroom</author>
          </item>
          <item>
            <title>No-date entry</title>
            <link>https://news.example/items/2</link>
            <guid>guid-2</guid>
          </item>
          <item>
            <title>Ancient entry</title>
            <link>https://news.example/items/3</link>
            <guid>guid-3</guid>
            <pubDate>\(rfc822(ancientDate))</pubDate>
          </item>
          <item>
            <title>X status link</title>
            <link>https://x.com/user/status/1234567890123456789</link>
          </item>
          <item>
            <title>Relative link</title>
            <link>/relative</link>
          </item>
        </channel></rss>
        """
        let result = try XRSSParser.parseGeneric(
            data: Data(xml.utf8),
            defaultAuthor: "news.example",
            maximumCount: 10,
            now: now
        )
        // relative 无 URL 跳过；ancient(Jul 26) 与 X(2010) 超三天窗口丢弃
        XCTAssertEqual(result.rawItemCount, 4)
        XCTAssertEqual(result.tweets.count, 2)

        let undated = try XCTUnwrap(result.tweets.first { $0.id == "guid-2" })
        XCTAssertEqual(undated.authorHandle, "news.example")
        XCTAssertEqual(undated.url.absoluteString, "https://news.example/items/2")
        let undatedDate = try XCTUnwrap(undated.publishedAt)
        XCTAssertEqual(undatedDate.timeIntervalSince(now), 0, accuracy: 60)
        XCTAssertEqual(undated.kind, .original)

        let dated = try XCTUnwrap(result.tweets.first { $0.id == "https://news.example/items/1" })
        XCTAssertEqual(dated.authorHandle, "newsroom")
        XCTAssertEqual(dated.text, "Launch: ready feature")
        let datedDate = try XCTUnwrap(dated.publishedAt)
        XCTAssertEqual(datedDate.timeIntervalSince(recentDate), 0, accuracy: 1)
    }

    func testGenericCapsAndExclusion() throws {
        let now = Date()
        let recent = Date(timeIntervalSince1970: now.addingTimeInterval(-1 * 24 * 60 * 60).timeIntervalSince1970.rounded())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        func date(_ i: Int) -> String { f.string(from: now.addingTimeInterval(Double(-i * 60))) }
        var xml = "<rss version=\"2.0\"><channel><title>Many</title>"
        for i in 0..<12 {
            xml += "<item><title>Item \(i)</title><link>https://news.example/m/\(i)</link><guid>m-\(i)</guid><pubDate>\(date(i))</pubDate></item>"
        }
        xml += "</channel></rss>"
        let result = try XRSSParser.parseGeneric(
            data: Data(xml.utf8),
            defaultAuthor: "news.example",
            maximumCount: 10,
            excludedTweetIDs: ["m-0", "m-1"],
            now: now
        )
        XCTAssertEqual(result.rawItemCount, 12, "rawItemCount 应计全部有效条目")
        // 页面构成稳定：截取固定选最新一页（m-0..m-9），排除已见只影响返回集，
        // 不得把更旧的 m-10/m-11 当作新条目顶上来。
        XCTAssertEqual(result.tweets.count, 8, "固定页面排除 2 条后应剩 8 条")
    }

    func testFatFeedDoesNotReplayHistoryAsNew() throws {
        let now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        func date(_ i: Int) -> String { f.string(from: now.addingTimeInterval(Double(-i * 60))) }
        var xml = "<rss version=\"2.0\"><channel><title>Fifteen</title>"
        for i in 0..<15 {
            xml += "<item><title>F \(i)</title><link>https://news.example/f/\(i)</link><guid>f-\(i)</guid><pubDate>\(date(i))</pubDate></item>"
        }
        xml += "</channel></rss>"
        let first = try XRSSParser.parseGeneric(
            data: Data(xml.utf8), defaultAuthor: "n", maximumCount: 10, excludedTweetIDs: [], now: now
        )
        let seenIDs = Set(first.tweets.map(\.id))
        XCTAssertEqual(seenIDs.count, 10)
        let second = try XRSSParser.parseGeneric(
            data: Data(xml.utf8), defaultAuthor: "n", maximumCount: 10,
            excludedTweetIDs: seenIDs, now: now
        )
        XCTAssertTrue(second.tweets.isEmpty, "同页全已见时应返回空，不得翻页重放历史")
    }
}
