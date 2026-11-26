import Foundation
import SwiftData

/// Imports pages saved by the extensions into the main app's SwiftData store.
///
/// Sources (all in the App Group `group.com.pagemind.app`):
/// - Share Extension queue: `pendingSavedPages` — JSON array of
///   `{url, title, savedAt}` written by PageMindShare.
/// - Safari Extension latest page: `latestSafariPage` — dictionary
///   `{title, text, url, date}` written by SafariWebExtensionHandler.
///
/// Called once on app launch (MainTabView `.task`). Imported entries are
/// removed from the queue so they are not imported twice. Pages already
/// in the Library (same URL) are skipped.
enum PendingPageImporter {
    static let appGroupID = "group.com.pagemind.app"
    static let pendingPagesKey = "pendingSavedPages"
    static let latestSafariPageKey = "latestSafariPage"

    /// One queued page from the Share Extension. Internal (not private)
    /// so unit tests can build queue entries and exercise the pure
    /// dedupe helpers below without a UserDefaults suite or a container.
    struct PendingSavedPage: Codable {
        let url: String
        let title: String
        let savedAt: Date
    }

    /// Pure helper: drops queued pages whose URL is already in the
    /// Library. Tested in PageMindTests.
    static func filterPending(
        _ pending: [PendingSavedPage],
        existingURLs: Set<String>
    ) -> [PendingSavedPage] {
        pending.filter { !existingURLs.contains($0.url) }
    }

    /// Pure helper: builds the SavedPage for a Safari Extension dict, or
    /// nil when there is nothing worth importing (no title/text, no URL,
    /// or the URL is already in the Library). Tested in PageMindTests.
    static func safariPageToImport(
        from dict: [String: Any],
        existingURLs: Set<String>
    ) -> SavedPage? {
        let title = dict["title"] as? String ?? ""
        let text = dict["text"] as? String ?? ""
        let url = dict["url"] as? String ?? ""
        let date = (dict["date"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date()
        guard (!title.isEmpty || !text.isEmpty), !url.isEmpty, !existingURLs.contains(url) else {
            return nil
        }
        return SavedPage(
            url: url,
            title: title.isEmpty ? url : title,
            readerText: text,
            excerpt: ReaderExtractor.excerpt(text, maxChars: 300),
            savedAt: date
        )
    }

    @MainActor
    static func importPendingPages(modelContext: ModelContext) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        var existingURLs: Set<String> = []
        if let existing = try? modelContext.fetch(FetchDescriptor<SavedPage>()) {
            existingURLs = Set(existing.map { $0.url })
        }

        var imported = 0

        // 1. Share Extension queue.
        if let data = defaults.data(forKey: pendingPagesKey),
           let pending = try? JSONDecoder().decode([PendingSavedPage].self, from: data) {
            for item in Self.filterPending(pending, existingURLs: existingURLs) {
                modelContext.insert(SavedPage(
                    url: item.url,
                    title: item.title,
                    readerText: "",
                    excerpt: "",
                    savedAt: item.savedAt
                ))
                existingURLs.insert(item.url)
                imported += 1
            }
            defaults.removeObject(forKey: pendingPagesKey)
        }

        // 2. Safari Extension latest page.
        if let dict = defaults.dictionary(forKey: latestSafariPageKey) {
            if let page = Self.safariPageToImport(from: dict, existingURLs: existingURLs) {
                modelContext.insert(page)
                imported += 1
            }
            defaults.removeObject(forKey: latestSafariPageKey)
        }

        if imported > 0 {
            try? modelContext.save()
        }
    }
}
