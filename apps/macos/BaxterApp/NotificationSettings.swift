import Foundation
import UserNotifications

protocol NotificationDispatching {
    func requestAuthorizationIfNeeded()
    func sendNotification(title: String, body: String)
}

struct NoopNotificationDispatcher: NotificationDispatching {
    func requestAuthorizationIfNeeded() {}
    func sendNotification(title: String, body: String) {}
}

final class UNUserNotificationDispatcher: NotificationDispatching {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorizationIfNeeded() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Intentionally ignore errors and authorization result; app remains functional.
        }
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { _ in
            // Best-effort notifications; do not surface local delivery failures to UI.
        }
    }
}

struct NotificationSettingsStore {
    static let shared = NotificationSettingsStore()
    private static let notifyOnSuccessKey = "baxter.notify_success"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var notifyOnSuccess: Bool {
        get { userDefaults.bool(forKey: Self.notifyOnSuccessKey) }
        nonmutating set { userDefaults.set(newValue, forKey: Self.notifyOnSuccessKey) }
    }
}
