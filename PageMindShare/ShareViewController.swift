import UIKit
import UniformTypeIdentifiers

/// Share Extension: save a page from Safari / any app into PageMind.
///
/// Reads NSExtensionItem attachments for `public.url` and
/// `public.plain-text`, extracts the URL, and appends a pending page
/// (url + title + savedAt) to the App Group shared UserDefaults
/// (suite `group.com.pagemind.app`, key `pendingSavedPages`) as JSON.
/// The main app imports pending pages on next launch.
///
/// Why shared UserDefaults + JSON, not a shared SwiftData store in v1:
/// a SwiftData store shared across the app and this extension needs a
/// shared container, a shared model container configuration, and
/// migration testing that is not done yet. The pending-pages queue is
/// simple, robust, and lets the main app own all SwiftData writes.
final class ShareViewController: UIViewController {

    private struct PendingSavedPage: Codable {
        let url: String
        let title: String
        let savedAt: Date
    }

    private static let appGroupID = "group.com.pagemind.app"
    private static let pendingPagesKey = "pendingSavedPages"

    override func viewDidLoad() {
        super.viewDidLoad()
        saveSharedPage()
    }

    private func saveSharedPage() {
        guard let extensionContext else {
            finish()
            return
        }
        guard let item = extensionContext.inputItems.first as? NSExtensionItem else {
            finish()
            return
        }

        var foundURL: URL?
        var foundTitle: String?
        // loadItem callbacks can arrive on any queue, so guard the
        // shared results with a lock (Swift 6 concurrency-safe).
        let lock = NSLock()
        let attachments = item.attachments ?? []
        let group = DispatchGroup()

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    lock.lock()
                    defer { lock.unlock() }
                    if let url = item as? URL {
                        foundURL = url
                    } else if let string = item as? String, let url = URL(string: string) {
                        foundURL = url
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    lock.lock()
                    defer { lock.unlock() }
                    if let string = item as? String {
                        if let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                           url.scheme != nil {
                            foundURL = url
                        } else if foundTitle == nil {
                            foundTitle = string
                        }
                    }
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if let url = foundURL {
                let title = foundTitle ?? item.attributedTitle?.string ?? url.host ?? url.absoluteString
                self.appendPendingPage(url: url, title: title)
            }
            self.finish()
        }
    }

    private func appendPendingPage(url: URL, title: String) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID) else { return }
        var pages: [PendingSavedPage] = []
        if let data = defaults.data(forKey: Self.pendingPagesKey),
           let decoded = try? JSONDecoder().decode([PendingSavedPage].self, from: data) {
            pages = decoded
        }
        pages.append(PendingSavedPage(url: url.absoluteString, title: title, savedAt: Date()))
        if let data = try? JSONEncoder().encode(pages) {
            defaults.set(data, forKey: Self.pendingPagesKey)
        }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
