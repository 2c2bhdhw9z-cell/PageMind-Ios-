import BackgroundTasks
import Foundation
import SwiftData
import SwiftUI
import UserNotifications

/// Morning Brief settings, persisted with @AppStorage.
/// One instance per view is fine here — the values are the settings
/// themselves, and every reader sees the same stored values — but the
/// scheduler reads them through this same type, not through a view.
@MainActor
final class MorningBriefSettings: ObservableObject {
    @AppStorage("briefEnabled") var isEnabled = false
    @AppStorage("briefHour") var hour = 7
    @AppStorage("briefMinute") var minute = 0
    /// Comma-separated topics, e.g. "AI news, markets".
    @AppStorage("briefTopics") var topics = ""
    @AppStorage("briefIncludeSavedPages") var includeSavedPages = true
    /// When the last brief was generated (0 = never).
    @AppStorage("briefLastGenerated") var lastGeneratedTimestamp: Double = 0

    var lastGenerated: Date? {
        lastGeneratedTimestamp > 0 ? Date(timeIntervalSince1970: lastGeneratedTimestamp) : nil
    }

    /// The next scheduled fire time for the chosen hour/minute.
    var nextFireDate: Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        let today = Calendar.current.date(from: components) ?? Date()
        if today > Date() {
            return today
        }
        return Calendar.current.date(byAdding: .day, value: 1, to: today) ?? today
    }

    var topicList: [String] {
        topics
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Generates the brief text from saved pages + web search.
/// Shared by the foreground "Generate now" button and the background task.
enum MorningBriefGenerator {
    /// Builds the brief Markdown. Throws on provider errors.
    @MainActor
    static func generate(
        settings: AppSettings,
        briefSettings: MorningBriefSettings,
        pages: [SavedPage]
    ) async throws -> String {
        let dateString = DateFormatter.localizedString(
            from: Date(), dateStyle: .medium, timeStyle: .none
        )
        var sections: [String] = []

        if briefSettings.includeSavedPages, !pages.isEmpty {
            let recent = pages
                .sorted { $0.savedAt > $1.savedAt }
                .prefix(5)
            let pageBlock = recent.map { page in
                let text = page.readerText.isEmpty ? page.excerpt : page.readerText
                return "- \(page.title) (\(page.url)): \(String(text.prefix(500)))"
            }.joined(separator: "\n")
            sections.append("Your recently saved pages:\n\(pageBlock)")
        }

        if !briefSettings.topicList.isEmpty {
            let search = WebSearchService()
            var topicBlock: [String] = []
            for topic in briefSettings.topicList.prefix(3) {
                let results = await search.search(query: topic, braveAPIKey: settings.braveAPIKey)
                let lines = results.prefix(3).map { "- \($0.title): \($0.url)" }
                if !lines.isEmpty {
                    topicBlock.append("Topic “\(topic)”:\n" + lines.joined(separator: "\n"))
                }
            }
            if !topicBlock.isEmpty {
                sections.append("Web results:\n" + topicBlock.joined(separator: "\n\n"))
            }
        }

        let context = sections.isEmpty
            ? "No saved pages and no topics were provided."
            : sections.joined(separator: "\n\n")
        let brief = try await ChatCompletion.ask(
            settings: settings,
            prompt: """
            Write a short Morning Brief for \(dateString).

            \(context)

            Format in Markdown:
            ## Morning Brief — \(dateString)
            A 2–3 sentence overview, then "### From your reading" (one bullet per saved page, with its key point) and "### On your topics" (one bullet per topic with what is new). If a section has no content, say "Nothing new." Keep the whole brief under 300 words.
            """,
            systemPrompt: "You write concise morning briefings. Only use the pages and web results provided."
        )
        return brief
    }
}

/// Background scheduling for the Morning Brief.
///
/// This is local, on-device scheduling: a BGAppRefreshTask registered
/// with BGTaskScheduler, plus a local notification when the brief is
/// ready. There is no server and no push. iOS decides exactly when a
/// background task runs and may delay it (low power, no network, app
/// rarely used) — the UI says so honestly, and "Generate now" always
/// works in the foreground.
enum MorningBriefScheduler {
    static let taskIdentifier = "com.pagemind.app.brief"
    static let notificationCategory = "com.pagemind.app.brief"

    /// Registers the background task handler. Called once at app launch
    /// (PageMindApp.init). Safe to call even when the brief is disabled.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // Reschedule first, so a failure still leaves tomorrow's brief queued.
            Task { @MainActor in scheduleNext() }
            Task {
                let success = await generateInBackground()
                refreshTask.setTaskCompleted(success: success)
            }
            refreshTask.expirationHandler = {
                refreshTask.setTaskCompleted(success: false)
            }
        }
    }

    /// Schedules the next brief at the user's chosen time.
    @MainActor
    static func scheduleNext() {
        let settings = MorningBriefSettings()
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = settings.nextFireDate
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Best-effort: the system may refuse (e.g. too many pending
            // tasks). The foreground "Generate now" path is unaffected.
        }
    }

    static func cancelPending() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    /// Asks for notification permission (needed to tell the user the
    /// brief is ready). Returns true when allowed.
    static func requestNotificationPermission() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// The background run: loads the recent pages, generates the brief,
    /// saves it as a Library note, and posts a notification. Returns
    /// whether the brief was saved.
    @MainActor
    private static func generateInBackground() async -> Bool {
        let settings = AppSettings.shared
        let briefSettings = MorningBriefSettings()
        guard briefSettings.isEnabled else { return true }

        let pages = loadRecentPages()
        do {
            let brief = try await MorningBriefGenerator.generate(
                settings: settings,
                briefSettings: briefSettings,
                pages: pages
            )
            let saved = saveBriefAsNote(brief)
            briefSettings.lastGeneratedTimestamp = Date().timeIntervalSince1970
            if saved {
                postReadyNotification()
            }
            return saved
        } catch {
            return false
        }
    }

    /// Loads recent saved pages for the background run. Uses the same
    /// App Group container as the app; falls back to no pages (not a
    /// crash) when the group is not provisioned yet.
    /// @MainActor because ModelContainer.mainContext is MainActor-isolated.
    @MainActor
    private static func loadRecentPages() -> [SavedPage] {
        let schema = Schema([SavedPage.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier("group.com.pagemind.app")
        )
        guard let container = try? ModelContainer(for: schema, configurations: [configuration]) else {
            return []
        }
        var descriptor = FetchDescriptor<SavedPage>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])
        descriptor.fetchLimit = 5
        return (try? container.mainContext.fetch(descriptor)) ?? []
    }

    /// @MainActor because ModelContainer.mainContext is MainActor-isolated.
    @MainActor
    private static func saveBriefAsNote(_ brief: String) -> Bool {
        let schema = Schema([SavedPage.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier("group.com.pagemind.app")
        )
        guard let container = try? ModelContainer(for: schema, configurations: [configuration]) else {
            return false
        }
        let dateString = DateFormatter.localizedString(
            from: Date(), dateStyle: .medium, timeStyle: .none
        )
        let page = SavedPage(
            url: "pagemind://brief/\(Int(Date().timeIntervalSince1970))",
            title: "Morning Brief — \(dateString)",
            readerText: brief,
            excerpt: ReaderExtractor.excerpt(brief, maxChars: 300),
            savedAt: Date()
        )
        container.mainContext.insert(page)
        do {
            try container.mainContext.save()
            return true
        } catch {
            return false
        }
    }

    private static func postReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Your Morning Brief is ready"
        content.body = "Open PageMind to read it."
        let request = UNNotificationRequest(
            identifier: "morning-brief-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
