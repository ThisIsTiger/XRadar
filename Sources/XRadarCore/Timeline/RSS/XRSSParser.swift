// XRSSParser.swift
// RSS 2.0 / Atom 解析与 X 字段映射（DESIGN-RSSHUB.md §5.3、§5.4、§5.5）
import Foundation
import os.log

public struct RSSParseResult: Sendable {
    /// 已排序、去重、截取并经过三天窗口过滤的推文。
    public let tweets: [Tweet]
    /// 去重且字段有效、未做三天窗口/已见 ID/截取过滤的条目数。
    public let rawItemCount: Int
}

public enum XRSSParser {
    private static let logger = Logger(subsystem: "com.xradar.app", category: "XRSSParser")
    private static let snowflakeEpochMs: UInt64 = 1288834974657
    private static let xLaunchDate = Date(timeIntervalSince1970: 1143858600) // 2006-04-01 附近，保守下限
    private static let maxItemLength = 100 * 1024
    private static let maxRawCandidates = 10
    private static let maxResponseSize = 5 * 1024 * 1024
    /// Snowflake 时间与 RSS 日期允许的最大偏差；超过时用 Snowflake 时间并记录诊断。
    private static let maxDateDiscrepancy: TimeInterval = 3600

    /// 解析 RSS/Atom 数据并映射为 X 推文。
    public static func parse(
        data: Data,
        requestHandle: String,
        maximumCount: Int,
        excludedTweetIDs: Set<String> = [],
        now: Date = Date()
    ) throws -> RSSParseResult {
        guard data.count <= maxResponseSize else {
            throw SourceError.responseTooLarge
        }
        let handle = requestHandle.lowercased()
        let entries = try Self.collectEntries(data: data)
        var tweets: [Tweet] = []
        tweets.reserveCapacity(entries.count)
        for entry in entries {
            guard let tweet = Self.mapEntry(entry, handle: handle, now: now) else { continue }
            tweets.append(tweet)
        }
        return Self.finalize(
            tweets: tweets,
            maximumCount: maximumCount,
            excludedTweetIDs: excludedTweetIDs,
            now: now
        )
    }

    /// 解析任意 RSS/Atom 源（DESIGN-RSSHUB.md §13）：不依赖 X 结构，
    /// 直接映射条目本身。`defaultAuthor` 用于无作者条目的归属（通常为域名）。
    public static func parseGeneric(
        data: Data,
        defaultAuthor: String,
        maximumCount: Int,
        excludedTweetIDs: Set<String> = [],
        now: Date = Date()
    ) throws -> RSSParseResult {
        guard data.count <= maxResponseSize else {
            throw SourceError.responseTooLarge
        }
        let entries = try Self.collectEntries(data: data)
        var tweets: [Tweet] = []
        tweets.reserveCapacity(entries.count)
        for entry in entries {
            guard let tweet = Self.mapGenericEntry(entry, defaultAuthor: defaultAuthor, now: now) else { continue }
            tweets.append(tweet)
        }
        return Self.finalize(
            tweets: tweets,
            maximumCount: maximumCount,
            excludedTweetIDs: excludedTweetIDs,
            now: now
        )
    }

    private static func collectEntries(data: Data) throws -> [FeedEntry] {
        let elements = try parseXML(data: data)
        return elements.flatMap { collectEntries(in: $0) }
    }

    /// 窗口 → 排序 → 截取 → 排除已见（§5.4/§5.5；顺序即语义）。
    ///
    /// 关键不变量：**"排除已见"必须最后做**。若先排除再截取，肥源（条目数
    /// 远超 maximumCount 的新闻 Feed）会在每轮把更旧的第 N+1..2N 条当作
    /// "新条目"顶上来——历史被当增量逐页重放。截取固定选取"最新一页"，
    /// 已见与否只决定该页里哪些算新。
    private static func finalize(
        tweets: [Tweet],
        maximumCount: Int,
        excludedTweetIDs: Set<String>,
        now: Date
    ) -> RSSParseResult {
        // 1. 按 Tweet ID 去重
        var byID: [String: Tweet] = [:]
        byID.reserveCapacity(tweets.count)
        for tweet in tweets where byID[tweet.id] == nil {
            byID[tweet.id] = tweet
        }
        var result = Array(byID.values)

        let rawItemCount = result.count

        // 2. 按 publishedAt 倒序；平局用数值 ID、再字符串 ID 决出确定性全序
        //    （Dictionary 遍历顺序随机，无全序则同秒条目的页面构成不稳定）。
        result.sort { lhs, rhs in
            let lhsTime = lhs.publishedAt ?? .distantPast
            let rhsTime = rhs.publishedAt ?? .distantPast
            if lhsTime != rhsTime { return lhsTime > rhsTime }
            let lhsNum = UInt64(lhs.id) ?? 0
            let rhsNum = UInt64(rhs.id) ?? 0
            if lhsNum != rhsNum { return lhsNum > rhsNum }
            return lhs.id > rhs.id
        }

        // 3. 三天窗口（先于截取与排除：陈旧条目不占页面名额）
        let cutoff = now.addingTimeInterval(-3 * 24 * 60 * 60)
        result.removeAll { ($0.publishedAt ?? .distantPast) < cutoff }

        // 4. 截取最多 min(maximumCount, 10) 条 —— 固定的"最新一页"
        let cap = min(max(1, maximumCount), maxRawCandidates)
        if result.count > cap {
            result.removeSubrange(result.index(result.startIndex, offsetBy: cap)..<result.endIndex)
        }

        // 5. 最后排除已见 ID：只影响本轮返回集，不影响页面构成
        if !excludedTweetIDs.isEmpty {
            result.removeAll { excludedTweetIDs.contains($0.id) }
        }

        return RSSParseResult(tweets: result, rawItemCount: rawItemCount)
    }

    // MARK: - XML 解析（安全：不解析外部实体、不加载 DTD）

    private static func parseXML(data: Data) throws -> [XMLElement] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = ElementParserDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw SourceError.invalidFeed
        }
        return delegate.roots
    }

    private static func collectEntries(in element: XMLElement) -> [FeedEntry] {
        var found: [FeedEntry] = []
        if let entry = FeedEntry(element: element) {
            found.append(entry)
        }
        for child in element.children {
            found.append(contentsOf: collectEntries(in: child))
        }
        return found
    }

    // MARK: - 条目映射

    private struct FeedEntry {
        let title: String
        let description: String
        let link: String
        let guid: String
        let dateString: String
        let authorName: String

        init?(element: XMLElement) {
            guard element.name == "item" || element.name == "entry" else { return nil }
            var title = ""
            var description = ""
            var link = ""
            var guid = ""
            var dateString = ""
            var authorName = ""

            for child in element.children {
                switch child.name {
                case "title":
                    title = child.plainText
                case "description", "content", "summary":
                    description = child.plainText
                case "link":
                    if let href = child.attributes["href"] {
                        link = href
                    } else {
                        link = child.plainText
                    }
                case "guid":
                    guid = child.plainText
                case "id":
                    if guid.isEmpty { guid = child.plainText }
                case "pubDate":
                    dateString = child.plainText
                case "published", "updated":
                    if dateString.isEmpty { dateString = child.plainText }
                case "author":
                    authorName = child.allChildren("name").first?.plainText ?? child.plainText
                default:
                    break
                }
            }
            self.title = title
            self.description = description
            self.link = link
            self.guid = guid
            self.dateString = dateString
            self.authorName = authorName
        }

        var plainText: String {
            title
        }
    }

    private static func mapEntry(_ entry: FeedEntry, handle: String, now: Date) -> Tweet? {
        // id：优先 canonical link 的 /status/{numericID}，其次 guid/id
        var numericID = Self.statusID(from: entry.link)
        if numericID == nil {
            numericID = Self.statusID(from: entry.guid)
        }
        guard let numericID else { return nil }

        // url：统一 host 为 x.com
        guard let url = URL(string: "https://x.com/\(handle)/status/\(numericID)") else {
            return nil
        }

        // 正文：优先 title，剥除固定类型前缀；空文本使用媒体占位文案
        var text = cleanHTML(entry.title, limit: maxItemLength)
        let (kind, stripped) = stripKindPrefix(text)
        text = stripped
        if text.isEmpty {
            text = cleanHTML(entry.description, limit: maxItemLength)
        }
        if text.isEmpty {
            text = "发布了一条媒体推文"
        }

        // 时间：优先 Snowflake 推导；RSS 日期用于交叉验证与 fallback
        let snowflakeTime = UInt64(numericID).flatMap { snowflakeDate(fromID: $0, now: now) }
        let rssDate = entry.dateString.isEmpty ? nil : parseRSSDate(entry.dateString)
        let publishedAt: Date?
        if let snowflakeTime {
            publishedAt = snowflakeTime
            if let rssDate, abs(rssDate.timeIntervalSince(snowflakeTime)) > maxDateDiscrepancy {
                logger.debug("Snowflake/RSS 时间不一致，使用 Snowflake 时间 (id=\(numericID))")
            }
        } else {
            publishedAt = rssDate
        }
        guard publishedAt != nil else { return nil }

        return Tweet(
            id: numericID,
            authorHandle: handle,
            text: text,
            url: url,
            publishedAt: publishedAt,
            kind: kind,
            isPinned: false
        )
    }

    /// 通用条目映射：不依赖 X 结构（§13）。
    /// id 优先 X 推文 ID（链接指向 x.com/status 时保持与 X 路径去重互通），
    /// 否则用 guid/link 原文；URL 必须是可解析的绝对 http(s) 地址；无日期条目按 now 处理。
    private static func mapGenericEntry(_ entry: FeedEntry, defaultAuthor: String, now: Date) -> Tweet? {
        // id：优先 X 推文 ID；其次 guid；最后 link
        var id = Self.statusID(from: entry.link)
        if id == nil {
            id = Self.statusID(from: entry.guid)
        }
        let guid = entry.guid.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == nil, !guid.isEmpty {
            id = guid
        }
        let link = entry.link.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == nil, !link.isEmpty {
            id = link
        }
        guard let id else { return nil }

        // url：link 或 guid 的绝对 http(s) URL；没有可跳转地址的条目直接跳过
        guard let url = Self.absoluteURL(from: link) ?? Self.absoluteURL(from: guid) else {
            return nil
        }

        // 正文：标题优先，其次摘要；空则跳过
        var text = cleanHTML(entry.title, limit: maxItemLength)
        if text.isEmpty {
            text = cleanHTML(entry.description, limit: maxItemLength)
        }
        guard !text.isEmpty else { return nil }

        // 时间：RSS 日期；链接是 X 推文时可用 Snowflake 推导；无日期按 now（视为新条目）
        let publishedAt: Date
        if let parsed = entry.dateString.isEmpty ? nil : parseRSSDate(entry.dateString) {
            publishedAt = parsed
        } else if let numeric = UInt64(id),
                  let snowflakeTime = snowflakeDate(fromID: numeric, now: now) {
            publishedAt = snowflakeTime
        } else {
            publishedAt = now
        }

        // 作者：条目作者名；缺失用源域名
        let authorName = cleanHTML(entry.authorName, limit: 40)
        let author = authorName.isEmpty ? defaultAuthor : authorName

        return Tweet(
            id: id,
            authorHandle: author,
            text: text,
            url: url,
            publishedAt: publishedAt,
            kind: .original,
            isPinned: false
        )
    }

    static func absoluteURL(from candidate: String) -> URL? {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              url.host != nil else {
            return nil
        }
        return url
    }

    // MARK: - 字段解析

    static func statusID(from candidate: String) -> String? {
        let decoded = decodeHTMLEntities(candidate)
        let pattern = #"/status/(\d+)"#
        guard let match = decoded.range(of: pattern, options: .regularExpression) else {
            // guid 可能是纯数字 ID
            let digits = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                return digits
            }
            return nil
        }
        return decoded[match]
            .split(separator: "/")
            .last
            .map(String.init)
    }

    static func snowflakeDate(fromID id: UInt64, now: Date) -> Date? {
        let ms = (id >> 22) + snowflakeEpochMs
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        guard date >= xLaunchDate, date <= now.addingTimeInterval(300) else { return nil }
        return date
    }

    static func stripKindPrefix(_ text: String) -> (kind: TweetKind, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("↩️") {
            return (.reply, String(trimmed.dropFirst("↩️".count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if trimmed.hasPrefix("🔁") {
            return (.repost, String(trimmed.dropFirst("🔁".count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (.original, trimmed)
    }

    static func parseRSSDate(_ string: String) -> Date? {
        let input = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // RFC 822/1123 数字时区: "Mon, 02 Jan 2006 15:04:05 +0000"
        if let date = Self.rfc822DateFormatter.date(from: input) {
            return date
        }
        // RFC 822 命名时区: "Mon, 02 Jan 2006 15:04:05 GMT"
        if let date = Self.rfc822NamedZoneFormatter.date(from: input) {
            return date
        }
        // ISO 8601
        if let date = Self.iso8601Formatter.date(from: input) {
            return date
        }
        if let date = Self.iso8601FractionalFormatter.date(from: input) {
            return date
        }
        return nil
    }

    private static var rfc822DateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter
    }

    private static var rfc822NamedZoneFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }

    private static var iso8601Formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static var iso8601FractionalFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    // MARK: - HTML 清洗

    /// 实体解码、去标签、空白归一化，并限制单条长度。
    static func cleanHTML(_ input: String, limit: Int) -> String {
        var result = decodeHTMLEntities(input)
        // CDATA 或双重编码时再解一次
        if result.contains("&") {
            result = decodeHTMLEntities(result)
        }
        result = result.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > limit {
            result = String(result.prefix(limit))
        }
        return result
    }

    static func decodeHTMLEntities(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = input
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "nbsp": " ", "hellip": "…", "mdash": "—", "ndash": "–",
            "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’",
            "rarr": "→", "larr": "←", "uarr": "↑", "darr": "↓"
        ]
        var index = output.startIndex
        while let ampRange = output.range(of: "&", range: index..<output.endIndex) {
            guard let semiRange = output.range(of: ";", range: ampRange.upperBound..<output.endIndex) else { break }
            let semi = semiRange.lowerBound
            let entity = output[ampRange.upperBound..<semi]
            let replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                let hex = entity.dropFirst(2)
                replacement = UInt32(hex, radix: 16).map { String(UnicodeScalar($0) ?? "\u{FFFD}") }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst()).map { String(UnicodeScalar($0) ?? "\u{FFFD}") }
            } else {
                replacement = named[String(entity)]
            }
            if let replacement {
                output.replaceSubrange(ampRange.lowerBound..<semiRange.upperBound, with: replacement)
                index = output.index(ampRange.lowerBound, offsetBy: replacement.count)
            } else {
                index = output.index(after: semi)
            }
        }
        return output
    }
}

// MARK: - XML 元素树

private final class XMLElement {
    let name: String
    var attributes: [String: String] = [:]
    var text = ""
    var children: [XMLElement] = []

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    func allChildren(_ name: String) -> [XMLElement] {
        children.filter { $0.name == name }
    }

    /// 文本与直接子元素文本的拼接（content/summary 含嵌套 HTML 时）。
    var plainText: String {
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        for child in children {
            let childText = child.plainText
            if !childText.isEmpty { parts.append(childText) }
        }
        return parts.joined(separator: " ")
    }
}

private final class ElementParserDelegate: NSObject, XMLParserDelegate {
    private(set) var roots: [XMLElement] = []
    private var stack: [XMLElement] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let element = XMLElement(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(element)
        } else {
            roots.append(element)
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
        stack.last?.text += string
    }
}
