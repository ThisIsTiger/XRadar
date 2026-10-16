// TelegramNotifier.swift
import Foundation

public actor TelegramNotifier: NotificationChannel {
    public let id: NotificationChannelID = .telegram

    private let keychainStore: any KeychainStoreProtocol
    private let session: URLSession

    /// - Parameters:
    ///   - keychainStore: Keychain access. Defaults to the real login keychain.
    ///   - session: URLSession used for the Bot API call. Defaults to a 10s-timeout
    ///     session. Tests inject a session backed by a `URLProtocol` mock.
    public init(
        keychainStore: any KeychainStoreProtocol = KeychainStore.shared,
        session: URLSession? = nil
    ) {
        self.keychainStore = keychainStore

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 10
            self.session = URLSession(configuration: config)
        }
    }

    public func send(_ event: NotificationEvent) async -> DeliveryResult {
        do {
            let token = try await keychainStore.loadTelegramBotToken()
            let chatID = try await keychainStore.loadTelegramChatID()

            let message = TelegramMessageFormatter.format(event: event)
            return await sendMessage(token: token, chatID: chatID, message: message, eventURL: event.tweetURL)
        } catch KeychainError.itemNotFound {
            return .failure("Telegram credentials not configured")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    public func sendTest() async -> DeliveryResult {
        do {
            let token = try await keychainStore.loadTelegramBotToken()
            let chatID = try await keychainStore.loadTelegramChatID()

            let message = "🧪 <b>XRadar 测试消息</b>\n\n如果您收到这条消息，说明 Telegram Bot 配置正确。"
            return await sendMessage(token: token, chatID: chatID, message: message, eventURL: nil)
        } catch KeychainError.itemNotFound {
            return .failure("Telegram credentials not configured")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func sendMessage(token: String, chatID: String, message: String, eventURL: URL?, retryDepth: Int = 0) async -> DeliveryResult {
        guard let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.telegram.org/bot\(encodedToken)/sendMessage") else {
            return .failure("Invalid Telegram bot token")
        }

        var keyboard: [[[String: String]]] = []
        if let eventURL = eventURL {
            keyboard = [[[
                "text": "查看原推文",
                "url": eventURL.absoluteString
            ]]]
        }

        let body: [String: Any] = [
            "chat_id": chatID,
            "text": message,
            "parse_mode": "HTML",
            "disable_web_page_preview": true,
            "reply_markup": [
                "inline_keyboard": keyboard
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return .failure("Failed to encode request: \(error.localizedDescription)")
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("Invalid response")
            }

            switch httpResponse.statusCode {
            case 200:
                return .success

            case 429:
                // Rate limited - retry once after retry_after (max 1 retry)
                guard retryDepth < 1 else {
                    return .failure("Rate limited (retry exhausted)")
                }
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let parameters = json["parameters"] as? [String: Any],
                   let retryAfter = parameters["retry_after"] as? Int {
                    let cappedWait = min(retryAfter, 30) // Cap at 30s
                    try? await Task.sleep(nanoseconds: UInt64(cappedWait) * 1_000_000_000)
                    return await sendMessage(token: token, chatID: chatID, message: message, eventURL: eventURL, retryDepth: retryDepth + 1)
                }
                return .failure("Rate limited")

            case 500...599:
                // Server error - retry once after 2 seconds (max 1 retry)
                guard retryDepth < 1 else {
                    return .failure("Server error (retry exhausted)")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return await sendMessage(token: token, chatID: chatID, message: message, eventURL: eventURL, retryDepth: retryDepth + 1)

            case 400...499 where httpResponse.statusCode != 429:
                // Client error - don't retry
                return .failure("Configuration error (HTTP \(httpResponse.statusCode))")

            default:
                return .failure("HTTP \(httpResponse.statusCode)")
            }
        } catch {
            return .failure("Network error: \(error.localizedDescription)")
        }
    }
}
