import AppKit
import UserNotifications

final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let urlString = response.notification.request.content.userInfo["tweetURL"] as? String,
              let url = URL(string: urlString),
              url.scheme == "https",
              let host = url.host?.lowercased(),
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(host) else {
            return
        }
        _ = await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }
}
