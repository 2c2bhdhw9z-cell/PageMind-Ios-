import SwiftUI
import SwiftData

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
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .identifier("group.com.pagemind.app")
        )
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // STUB: Fallback to an in-memory container if the shared
            // App Group container cannot be created (e.g. group not
            // provisioned yet). Data will not persist in that case.
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
            if hasSeenOnboarding {
                MainTabView()
            } else {
                OnboardingView()
            }
        }
        .modelContainer(sharedModelContainer)
        .environmentObject(AppSettings.shared)
    }
}

/// Shared in-memory handoff from Browser ("Ask about this page") to Chat.
/// BrowserView sets `pendingPage` and bumps `askRequestID`; MainTabView
/// switches to the Chat tab, and ChatView picks the page up as context.
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

struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var pageContext = PageContextStore()
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            BrowserView()
                .tabItem {
                    Label("Browser", systemImage: "globe")
                }
                .tag(0)

            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "books.vertical")
                }
                .tag(1)

            ChatView()
                .tabItem {
                    Label("Chat", systemImage: "message")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(3)
        }
        .environmentObject(pageContext)
        .onChange(of: pageContext.askRequestID) { _, _ in
            selection = 2
        }
        .task {
            // Import pages saved from the Share / Safari extensions
            // while the app was not running.
            PendingPageImporter.importPendingPages(modelContext: modelContext)
            let pages = (try? modelContext.fetch(FetchDescriptor<SavedPage>())) ?? []
            WidgetDataWriter.writeSnapshot(pages: pages)
        }
    }
}
