import WidgetKit
import SwiftUI

/// PageMind widgets.
///
/// Small: count of pages saved today + a "Quick ask" deep link (pagemind://ask).
/// Medium: the 3 most recent saved page titles.
///
/// Data source: the App Group shared UserDefaults (suite
/// `group.com.pagemind.app`). The main app writes a snapshot of the 3
/// most recent pages to `widgetRecentPages` whenever the Library
/// changes (see WidgetDataWriter), and the Share Extension writes
/// not-yet-imported pages to `pendingSavedPages`. The widget reads
/// both and dedupes by URL, so it shows recent pages whether or not
/// the app has imported them yet.
///
/// Limitation, stated plainly: this only works once the App Group
/// `group.com.pagemind.app` is provisioned, which needs an Apple
/// Developer account (see BUILD-NOTES). Until then,
/// `UserDefaults(suiteName:)` returns nil, the widget cannot see the
/// Library, and it shows the "open PageMind" state below instead of
/// fake numbers. A shared SwiftData store for widgets is the follow-up
/// once the group exists — it needs the same entitlement.

private struct SharedPendingPage: Codable {
    let url: String
    let title: String
    let savedAt: Date
}

private struct PageMindEntry: TimelineEntry {
    let date: Date
    let savedTodayCount: Int
    let recentTitles: [String]
}

private struct PageMindProvider: TimelineProvider {
    func placeholder(in context: Context) -> PageMindEntry {
        PageMindEntry(date: Date(), savedTodayCount: 3, recentTitles: ["Saved page one", "Saved page two", "Saved page three"])
    }

    func getSnapshot(in context: Context, completion: @escaping (PageMindEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PageMindEntry>) -> Void) {
        let entry = loadEntry()
        let nextUpdate = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func loadEntry() -> PageMindEntry {
        // Read both shared stores and dedupe by URL: the app's snapshot
        // (recent pages, already imported) and the pending queue (saved
        // from an extension, not yet imported).
        guard let defaults = UserDefaults(suiteName: "group.com.pagemind.app") else {
            // App Group not provisioned yet (no Apple Developer account):
            // no data is visible to the widget. Return an honest empty
            // entry rather than a made-up count.
            return PageMindEntry(date: Date(), savedTodayCount: 0, recentTitles: [])
        }
        var pages: [SharedPendingPage] = []
        if let data = defaults.data(forKey: "widgetRecentPages"),
           let decoded = try? JSONDecoder().decode([SharedPendingPage].self, from: data) {
            pages.append(contentsOf: decoded)
        }
        if let data = defaults.data(forKey: "pendingSavedPages"),
           let decoded = try? JSONDecoder().decode([SharedPendingPage].self, from: data) {
            pages.append(contentsOf: decoded)
        }
        var seenURLs = Set<String>()
        let unique = pages
            .sorted { $0.savedAt > $1.savedAt }
            .filter { seenURLs.insert($0.url).inserted }
        let todayCount = unique.filter { Calendar.current.isDateInToday($0.savedAt) }.count
        let recent = unique.prefix(3).map(\.title)
        return PageMindEntry(date: Date(), savedTodayCount: todayCount, recentTitles: Array(recent))
    }
}

private struct PageMindWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: PageMindEntry

    var body: some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 8) {
                Text("\(entry.savedTodayCount)")
                    .font(.largeTitle.bold())
                Text(entry.savedTodayCount == 1 ? "page saved today" : "pages saved today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Link("Quick ask", destination: URL(string: "pagemind://ask")!)
                    .font(.callout.bold())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent pages")
                    .font(.headline)
                if entry.recentTitles.isEmpty {
                    Text("No pages saved yet — open PageMind and save one. (Widgets sync once the App Group is set up; see the build notes.)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entry.recentTitles, id: \.self) { title in
                        Text(title)
                            .font(.subheadline)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Link("Quick ask", destination: URL(string: "pagemind://ask")!)
                    .font(.callout.bold())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding()
        }
    }
}

@main
struct PageMindWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PageMindWidgets", provider: PageMindProvider()) { entry in
            PageMindWidgetView(entry: entry)
        }
        .configurationDisplayName("PageMind")
        .description("Pages saved today and your most recent saved pages.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
