import SafariServices
import os.log

/// Native handler for the PageMind Safari Web Extension.
///
/// Receives `pageText` messages from content.js, stores the latest page
/// (title + text + url + date) into the App Group shared UserDefaults
/// (key `latestSafariPage`) for the main app to pick up, and replies with
/// a simple acknowledgement dictionary.
///
/// STUB: the native <-> JS bridge needs on-device testing in Safari.
/// The message format, the shared-defaults write and the reply below are
/// written to the Safari Web Extension API as documented, but the round
/// trip (content script -> background -> native handler -> main app)
/// has not been verified on a device yet. The main app imports the
/// stored page on launch via PendingPageImporter.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    private static let appGroupID = "group.com.pagemind.app"
    private static let latestPageKey = "latestSafariPage"

    func beginRequest(with context: NSExtensionContext) {
        guard let item = context.inputItems.first as? NSExtensionItem,
              let message = item.userInfo?[SFExtensionMessageKey] as? [String: Any] else {
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }

        if message["type"] as? String == "pageText" {
            storeLatestPage(message)
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["received": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func storeLatestPage(_ message: [String: Any]) {
        let title = message["title"] as? String ?? ""
        let text = message["text"] as? String ?? ""
        let url = message["url"] as? String ?? ""
        guard !title.isEmpty || !text.isEmpty else { return }

        let page: [String: Any] = [
            "title": title,
            "text": text,
            "url": url,
            "date": Date().timeIntervalSince1970
        ]
        guard let defaults = UserDefaults(suiteName: Self.appGroupID) else { return }
        defaults.set(page, forKey: Self.latestPageKey)
        os_log("PageMind Safari extension stored latest page: %{public}@", log: .default, type: .info, title)
    }
}
