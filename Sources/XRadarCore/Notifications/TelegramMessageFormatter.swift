// TelegramMessageFormatter.swift
import Foundation

enum TelegramMessageFormatter {
    static func format(event: NotificationEvent) -> String {
        var parts: [String] = []

        // Title
        parts.append("🔔 <b>\(escapeHTML(event.title))</b>")

        // Matched keywords
        if !event.matchedKeywords.isEmpty {
            let keywords = event.matchedKeywords.joined(separator: ", ")
            parts.append("🎯 命中: \(escapeHTML(keywords))")
        }

        // Tweet body
        let tweetText = event.body.isEmpty ? "发布了一条媒体推文" : event.body
        parts.append("\n\(escapeHTML(tweetText))")

        return parts.joined(separator: "\n")
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
