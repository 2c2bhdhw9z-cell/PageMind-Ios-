import SwiftUI
import SwiftData

/// Whether the App Group container is actually available to this build.
/// SwiftData fatally crashes inside ModelContainer init (instead of
/// throwing) when the group identifier has no entitlement, so callers
/// must check this BEFORE passing groupContainer: .identifier(...).
/// Unsigned CI / sideloaded builds have no entitlement and return nil.
enum AppGroup {
    static let identifier = "group.com.pagemind.app"
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }
}

@main
struct PageMindApp: App {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Chat.self,
            ChatMessage.self,
            SavedPage.self,
            CollectionModel.self,
        ])
        if AppGroup.isAvailable {
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                groupContainer: .identifier(AppGroup.identifier)
            )
            if let container = try? ModelContainer(for: schema, configurations: [modelConfiguration]) {
                return container
            }
        }
        // No App Group entitlement (CI / unsigned / sideloaded): local
        // on-disk store, then in-memory as a last resort. Data persists
        // per install but is not shared with extensions/widgets yet.
        do {
            return try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    init() {
        // Registers the Morning Brief background task (BGTaskScheduler).
        // Registration must happen at launch, before the system can deliver
        // the task. If the brief is not enabled, registration is harmless.
        MorningBriefScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasSeenOnboarding {
                    AppShellView()
                } else {
                    OnboardingView()
                }
            }
            // Appearance settings (Settings → General) applied app-wide:
            // theme, text size, and display language. These read the
            // shared AppSettings instance, so changing them in Settings
            // takes effect immediately.
            .preferredColorScheme(AppSettings.shared.preferredColorScheme)
            .dynamicTypeSize(AppSettings.shared.preferredTypeSize)
            .environment(\.locale, AppSettings.shared.preferredLocale)
        }
        .modelContainer(sharedModelContainer)
        .environmentObject(AppSettings.shared)
    }
}

/// Shared in-memory handoff from Browser ("Ask about this page") to Chat.
/// BrowserView sets `pendingPage` and bumps `askRequestID`; AppShellView
/// switches to the Chat destination, and ChatView picks the page up as context.
@MainActor
final class PageContextStore: ObservableObject {
    @Published var pendingPage: SavedPage?
    @Published var askRequestID = UUID()

    func askAbout(page: SavedPage) {
        pendingPage = page
        askRequestID = UUID()
    }

    func takePendingPage() -> SavedPage? {
        defer { pendingPage = nil }
        return pendingPage
    }
}
