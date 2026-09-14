import Foundation
import UserNotifications

/// Created only by the normal app, never by preview/test models.
final class QuotaGuardNotifications: NSObject, QuotaNotificationAdapter, UNUserNotificationCenterDelegate {
    private(set) static var constructionCount = 0
    private let center: UNUserNotificationCenter
    private var pendingActions: [(String, Bool)] = []
    var action: ((String, Bool) -> Void)? {
        didSet {
            guard let action else { return }
            let queued = pendingActions; pendingActions = []
            for (id, snooze) in queued { action(id, snooze) }
        }
    }
    override init() {
        Self.constructionCount += 1
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
        let view = UNNotificationAction(identifier: "view-quota", title: "View quota", options: .foreground)
        let snooze = UNNotificationAction(identifier: "snooze-quota", title: "Snooze 30 min", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: "quota-guard", actions: [view, snooze], intentIdentifiers: [], options: [])])
    }
    func permission(request: Bool, completion: @escaping (QuotaNotificationPermission) -> Void) {
        func read() {
            center.getNotificationSettings { settings in
                let permission: QuotaNotificationPermission
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: permission = .authorized
                case .denied: permission = .denied
                case .notDetermined: permission = .notDetermined
                @unknown default: permission = .unavailable
                }
                DispatchQueue.main.async { completion(permission) }
            }
        }
        if request { center.requestAuthorization(options: [.alert, .sound]) { _, _ in read() } }
        else { read() }
    }
    func submit(_ notification: QuotaNotification, completion: @escaping (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = notification.title; content.body = notification.body
        content.categoryIdentifier = "quota-guard"
        if notification.sound { content.sound = .default }
        // Request identifier is the only route: no account ID or user text in payload.
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil)) { error in
            DispatchQueue.main.async { completion(error == nil) }
        }
    }
    func pending(_ completion: @escaping (Set<String>) -> Void) {
        center.getPendingNotificationRequests { requests in
            let ids = Set(requests.map(\.identifier).filter { $0.hasPrefix("quota-") })
            DispatchQueue.main.async { completion(ids) }
        }
    }
    func delivered(_ completion: @escaping (Set<String>) -> Void) {
        center.getDeliveredNotifications { values in
            let ids = Set(values.map { $0.request.identifier }.filter { $0.hasPrefix("quota-") })
            DispatchQueue.main.async { completion(ids) }
        }
    }
    func remove(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids); center.removeDeliveredNotifications(withIdentifiers: ids) }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        guard id.hasPrefix("quota-"), response.actionIdentifier != UNNotificationDismissActionIdentifier else { completionHandler(); return }
        DispatchQueue.main.async {
            let snooze = response.actionIdentifier == "snooze-quota"
            if let action = self.action { action(id, snooze) }
            else if self.pendingActions.count < 16 { self.pendingActions.append((id, snooze)) }
            completionHandler()
        }
    }
}
