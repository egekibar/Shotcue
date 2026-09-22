import Foundation
import ShotcueCore
import UserNotifications

/// Run notifications with actions (spec §6.7). The identifiers are public so Plan 06's
/// `UNUserNotificationCenterDelegate` can match them without duplicating string literals.
public final class UserNotificationNotifier: Notifier, @unchecked Sendable {
    public static let runDoneCategory = "RUN_DONE"
    public static let runFailedCategory = "RUN_FAILED"
    public static let openAction = "OPEN"
    public static let terminalAction = "TERMINAL"
    public static let retryAction = "RETRY"
    public static let taskIDKey = "taskID"
    public static let runIDKey = "runID"

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    /// Called once at launch, before the first `notify`.
    public func registerCategories() {
        center.setNotificationCategories(Self.categories())
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func notify(_ notification: AppNotification) async {
        try? await center.add(Self.request(for: notification))
    }

    // MARK: - Pure parts (unit tested without the real center)

    public static func categories() -> Set<UNNotificationCategory> {
        let open = UNNotificationAction(identifier: openAction, title: "Aç", options: [.foreground])
        let terminal = UNNotificationAction(identifier: terminalAction, title: "Terminalde devam et", options: [])
        let retry = UNNotificationAction(identifier: retryAction, title: "Yeniden çalıştır", options: [])
        return [
            UNNotificationCategory(
                identifier: runDoneCategory, actions: [open, terminal],
                intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: runFailedCategory, actions: [open, retry],
                intentIdentifiers: [], options: []),
        ]
    }

    public static func request(for notification: AppNotification) -> UNNotificationRequest {
        let failed = notification.kind == .runFailed
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = failed ? runFailedCategory : runDoneCategory
        content.interruptionLevel = failed ? .timeSensitive : .active
        var info: [String: String] = [:]
        if let taskID = notification.taskID { info[taskIDKey] = taskID.uuidString }
        if let runID = notification.runID { info[runIDKey] = runID.uuidString }
        content.userInfo = info
        let identifier = notification.runID?.uuidString ?? UUID().uuidString
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}
