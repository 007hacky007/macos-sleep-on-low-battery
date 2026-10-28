import Foundation
import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter { .current() }

    func configure() {
        center.delegate = self
    }

    /// Returns whether alerts are allowed.
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func postSleepNotification(percentage: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Battery Sleep Guard"
        content.body = "Battery reached \(percentage)%. Putting Mac to sleep."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }

    func postEarlyWarning(minutes: Int, at date: Date, threshold: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "Battery Sleep Guard"
        content.body = "Battery should reach \(threshold)% in about \(minutes) min (at \(date.formatted(date: .omitted, time: .shortened))). The Mac will go to sleep then unless you plug in."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "early-warning", content: content, trigger: nil)
        try? await center.add(request)
    }

    // Show the banner even while the menu bar window is open (the app counts as active then).
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
