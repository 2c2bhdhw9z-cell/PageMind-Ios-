import Foundation

/// Writes a small snapshot of the Library into the App Group shared
/// UserDefaults so the widgets can show recent pages and today's count.
///
/// The snapshot is the only channel widgets have: a widget cannot open
/// the main app's SwiftData store directly, and a shared SwiftData store
/// needs the App Group entitlement (see BUILD-NOTES — still open, needs
/// Apple Developer). Until the group is provisioned,
/// `UserDefaults(suiteName:)` returns nil and this writer is a silent
/// no-op; the widgets then show their "open PageMind to sync" state.
///
/// Call after any change to saved pages: BrowserView save, and
/// MainTabView's pending-page import.
enum WidgetDataWriter {
    static let appGroupID = "group.com.pagemind.app"
    static let snapshotKey = "widgetRecentPages"

    private struct SnapshotPage: Codable {
        let url: String
        let title: String
        let savedAt: Date
    }

    /// Writes the 3 most recent pages (title + URL + date) to the shared
    /// defaults. The widget counts "saved today" from the dates.
    static func writeSnapshot(pages: [SavedPage]) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let recent = pages
            .sorted { $0.savedAt > $1.savedAt }
            .prefix(3)
            .map { SnapshotPage(url: $0.url, title: $0.title, savedAt: $0.savedAt) }
        guard let data = try? JSONEncoder().encode(Array(recent)) else { return }
        defaults.set(data, forKey: snapshotKey)
    }
}
