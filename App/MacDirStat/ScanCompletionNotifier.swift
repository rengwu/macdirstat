import AppKit
import UserNotifications

/// Telling the user a scan finished while they were somewhere else.
///
/// Behind a seam for the same reason ``AccessibilityAnnouncing`` is: a spy is
/// the only way to assert that a completed scan posted something, and the real
/// implementation talks to a system service that is unavailable — and noisy
/// about it — in a test host.
@MainActor
protocol ScanCompletionNotifying: AnyObject {
    func notifyScanFinished(title: String, body: String)
}

@MainActor
final class SystemScanCompletionNotifier: ScanCompletionNotifying {
    private var authorization: Authorization = .unasked

    private enum Authorization {
        case unasked
        case granted
        case denied
    }

    func notifyScanFinished(title: String, body: String) {
        switch authorization {
        case .denied:
            return
        case .granted:
            post(title: title, body: body)
        case .unasked:
            requestThenPost(title: title, body: body)
        }
    }

    /// Asked on the first finished scan rather than at launch: a permission
    /// prompt before the user has scanned anything is a prompt about a thing
    /// they have not done yet.
    private func requestThenPost(title: String, body: String) {
        guard let center = center else {
            authorization = .denied
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorization = granted ? .granted : .denied
                guard granted else { return }
                self.post(title: title, body: body)
            }
        }
    }

    private func post(title: String, body: String) {
        guard let center = center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    /// `UNUserNotificationCenter.current()` traps outright when the running
    /// binary has no bundle identifier — which is exactly the shape of an
    /// `xctest` host — so the centre is fetched through this and never stored.
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}

/// Records what would have been posted.
@MainActor
final class RecordingScanCompletionNotifier: ScanCompletionNotifying {
    private(set) var posted: [(title: String, body: String)] = []

    func notifyScanFinished(title: String, body: String) {
        posted.append((title, body))
    }
}
