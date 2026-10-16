// MacOSLocalNotifier.swift
import Foundation
import UserNotifications

public actor MacOSLocalNotifier: NotificationChannel {
    public let id: NotificationChannelID = .macOS
    private var soundEnabled = true

    public init() {}

    public func setSoundEnabled(_ enabled: Bool) {
        self.soundEnabled = enabled
    }

    public func send(_ event: NotificationEvent) async -> DeliveryResult {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = String(event.body.prefix(220))
        content.sound = self.soundEnabled ? .default : nil
        content.categoryIdentifier = "XRADAR_TWEET"
        content.userInfo = [
            "tweetURL": event.tweetURL.absoluteString,
            "eventID": event.id
        ]

        let request = UNNotificationRequest(
            identifier: event.id,
            content: content,
            trigger: nil // Immediate
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return .success
        } catch {
            let errStr = error.localizedDescription
            if errStr.contains("UNErrorDomain error 1") || errStr.contains("notificationsNotAllowed") {
                return .failure("macOS 通知权限未开启（请在系统设置 -> 通知中允许 XRadar 发送通知）")
            }
            return .failure(errStr)
        }
    }

    public func sendTest() async -> DeliveryResult {
        let content = UNMutableNotificationContent()
        content.title = "XRadar 测试通知"
        content.body = "如果您看到这条通知，说明 macOS 通知功能正常工作。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
