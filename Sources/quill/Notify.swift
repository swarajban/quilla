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
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(title: String, body: String) {
        guard bundled else {
            osascriptNotify(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { Notify.onOpen?() }
    }
}

/// Backwards-compatible free function — existing call sites unchanged.
func notifyUser(title: String, body: String) {
    Notify.send(title: title, body: body)
}
