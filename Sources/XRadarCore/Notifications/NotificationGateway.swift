// NotificationGateway.swift
import Foundation
import os.log
import UserNotifications

public actor NotificationGateway {
    private static let logger = Logger(subsystem: "com.xradar.app", category: "NotificationGateway")
    private let channels: [NotificationChannelID: any NotificationChannel]
    private var enabledChannelIDs = Set(NotificationChannelID.allCases)

    public init(channels: [any NotificationChannel]) {
        var channelMap: [NotificationChannelID: any NotificationChannel] = [:]
        for channel in channels {
            channelMap[channel.id] = channel
        }
        self.channels = channelMap
    }

    public func configure(
        macOSEnabled: Bool,
        macOSSoundEnabled: Bool,
        telegramEnabled: Bool
    ) async {
        var enabled: Set<NotificationChannelID> = []
        if macOSEnabled {
            enabled.insert(.macOS)
        }
        if telegramEnabled {
            enabled.insert(.telegram)
        }
        self.enabledChannelIDs = enabled

        if let notifier = self.channels[.macOS] as? MacOSLocalNotifier {
            await notifier.setSoundEnabled(macOSSoundEnabled)
        }
    }

    public func requestPermissions() async {
        // Notifications require a properly bundled app (a registered bundle
        // identifier). When launched as a bare executable -- e.g. a headless
        // smoke test, or a mis-packaged build -- UNUserNotificationCenter
        // cannot determine the bundle identifier and throws an uncatchable
        // Objective-C exception. Guard against that so the app never crashes
        // at launch. In a real distributed `.app` the bundle identifier is
        // always present, so this path is a no-op there.
        guard Bundle.main.bundleIdentifier != nil else {
            Self.logger.info("Skipping notification permission request: no bundle identifier (app not bundled).")
            return
        }
        do {
            let center = UNUserNotificationCenter.current()
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            Self.logger.info("Notification permission granted: \(granted)")

            // Register notification categories
            let openAction = UNNotificationAction(
                identifier: "OPEN_TWEET",
                title: "查看推文",
                options: .foreground
            )

            let category = UNNotificationCategory(
                identifier: "XRADAR_TWEET",
                actions: [openAction],
                intentIdentifiers: [],
                options: []
            )

            center.setNotificationCategories([category])
        } catch {
            Self.logger.error("Failed to request notification permission: \(error.localizedDescription)")
        }
    }

    public func deliver(
        event: NotificationEvent,
        through channelIDs: Set<NotificationChannelID>
    ) async -> [NotificationChannelID: DeliveryResult] {
        var results: [NotificationChannelID: DeliveryResult] = [:]

        await withTaskGroup(of: (NotificationChannelID, DeliveryResult).self) { group in
            for channelID in channelIDs {
                guard enabledChannelIDs.contains(channelID) else { continue }
                guard let channel = channels[channelID] else { continue }

                group.addTask {
                    let result = await channel.send(event)
                    return (channelID, result)
                }
            }

            for await (channelID, result) in group {
                results[channelID] = result
            }
        }

        return results
    }

    public func sendTest(to channelID: NotificationChannelID) async -> DeliveryResult {
        guard let channel = channels[channelID] else {
            return .failure("Channel not found")
        }
        return await channel.sendTest()
    }
}
