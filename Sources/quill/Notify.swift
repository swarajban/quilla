import Foundation
import UserNotifications

/// User-visible notification. Inside the packaged .app, quill owns its
/// notifications via UNUserNotificationCenter — they show as "quill", and a
/// click fires `onOpen` (recordings folder) instead of opening Script
/// Editor. A bare binary (dev build straight from .build/) can't touch that
/// API without an uncatchable ObjC crash, so it falls back to osascript.
enum Notify {
    /// Click handler for notifications — set by AppController (main actor).
    @MainActor static var onOpen: (() -> Void)?
    /// "Start recording" handler for meeting-detected notifications.
    @MainActor static var onRecord: (() -> Void)?

    /// Notification category for the meeting detector — carries a "Start
    /// recording" action button; clicking the banner body does the same.
    static let meetingCategory = "meeting-detected"
    private static let recordAction = "record"

    private static let delegate = NotificationDelegate()

    private static var bundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    /// Set the delegate and ask for notification permission once (first
    /// launch of the .app prompts; harmless thereafter).
    static func configure() {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: meetingCategory,
                actions: [
                    UNNotificationAction(
                        identifier: recordAction,
                        title: "Start recording",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String, category: String? = nil) {
        guard bundled else {
            osascriptNotify(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let category { content.categoryIdentifier = category }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                FileHandle.standardError.write(Data("notify failed: \(error)\n".utf8))
            }
        }
    }

    /// Legacy path for unbundled dev runs: the notification is attributed to
    /// Script Editor (clicking it opens Script Editor — cosmetic).
    private static func osascriptNotify(title: String, body: String) {
        func quoted(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let script = "display notification \(quoted(body)) with title \(quoted(title))"
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
    }
}

/// Show banners even while quill is "frontmost" (menu-bar apps often are),
/// and route notification clicks to Notify.onOpen.
private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let isMeeting = response.notification.request.content.categoryIdentifier
            == Notify.meetingCategory
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        if isMeeting && (isDefault || response.actionIdentifier == "record") {
            await MainActor.run { Notify.onRecord?() }
        } else if isDefault {
            await MainActor.run { Notify.onOpen?() }
        }
    }
}

/// Backwards-compatible free function — existing call sites unchanged.
func notifyUser(title: String, body: String, category: String? = nil) {
    Notify.send(title: title, body: body, category: category)
}
