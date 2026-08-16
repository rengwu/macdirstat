import AppKit

/// The two read-only file actions, behind a seam so a test can prove which URL
/// was passed and that nothing else was ever called (spec §10, §9.3).
///
/// Read-only is **structural** here in exactly the way it is for
/// `ScanCore.DirectoryProbe`: the protocol has two methods and there is no
/// third one to call. Adding a mutating method would be a visible change to
/// this declaration, not a slip inside a view controller.
@MainActor
protocol WorkspaceActing: AnyObject {
    /// `NSWorkspace.open(_:)` — hands the URL to the system's default handler.
    func open(_ url: URL)
    /// `NSWorkspace.activateFileViewerSelecting(_:)` — selects it in Finder.
    func reveal(_ url: URL)
}

@MainActor
final class SystemWorkspaceActions: WorkspaceActing {
    func open(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// VoiceOver announcements, injectable for the same reason: §9.4 requires an
/// announcement when the shared selection changes, and a spy is the only way to
/// assert one was posted without driving VoiceOver itself.
@MainActor
protocol AccessibilityAnnouncing: AnyObject {
    func announce(_ message: String)
}

@MainActor
final class SystemAccessibilityAnnouncer: AccessibilityAnnouncing {
    func announce(_ message: String) {
        guard let target = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}
