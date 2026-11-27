import SwiftUI
import SwiftData

// MARK: - Shared design tokens

/// Small shared design tokens for the app shell.
///
/// `appBackground` is secondarySystemBackground: a very dark grey in
/// dark mode (#1C1C1E) and a light grey in light mode — never pure
/// black, so the home screen does not read as an empty black void.
enum PageMindDesign {
    static let appBackground = Color(uiColor: .secondarySystemBackground)
    static let cardBackground = Color.secondary.opacity(0.12)
    static let rowSpacing: CGFloat = 20
}

// MARK: - Shell state

/// The destinations the sidebar can show in the detail column.
enum AppDestination: String, Hashable {
    case chat
    case search
    case library
    case browser
    case compare
    case morningBrief
    case deepResearch
    case settings
}

/// Shared navigation state for the app shell, owned by AppShellView
/// and read by the sidebar and the detail views.
@MainActor
final class AppShellState: ObservableObject {
    @Published var selection: AppDestination = .chat
    @Published var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// The chat the sidebar asked ChatView to open (nil = no request).
    @Published var openChat: Chat?
    /// Bumped whenever the sidebar asks for a brand-new chat.
    @Published var newChatNonce = UUID()
    @Published var showingPaywall = false

    func openNewChat() {
        openChat = nil
        newChatNonce = UUID()
        selection = .chat
    }

    func openChat(_ chat: Chat) {
        openChat = chat
        selection = .chat
    }
}

/// The leading toolbar button that re-opens the sidebar on iPhone.
/// On iPad the sidebar is already visible; the button is harmless there.
struct SidebarToggleButton: View {
    @EnvironmentObject private var shell: AppShellState

    var body: some View {
        Button {
            shell.columnVisibility = .all
        } label: {
            Label("Menu", systemImage: "sidebar.leading")
        }
    }
}

// MARK: - App shell

/// Chat-first app shell: a drawer-style sidebar (NavigationSplitView)
/// with the chat as the home detail. Replaces the old four-tab bar
/// (MainTabView).
struct AppShellView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var shell = AppShellState()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var pageContext = PageContextStore()

    var body: some View {
        NavigationSplitView(columnVisibility: $shell.columnVisibility) {
            SidebarView()
        } detail: {
            detailView
        }
        .environmentObject(shell)
        .environmentObject(pageContext)
        .onChange(of: pageContext.askRequestID) { _, _ in
            // "Ask about this page" from the Browser tab: jump to Chat.
            shell.selection = .chat
            if horizontalSizeClass == .compact {
                shell.columnVisibility = .detailOnly
            }
        }
        .task {
            // Import pages saved from the Share / Safari extensions
            // while the app was not running.
            PendingPageImporter.importPendingPages(modelContext: modelContext)
            let pages = (try? modelContext.fetch(FetchDescriptor<SavedPage>())) ?? []
            WidgetDataWriter.writeSnapshot(pages: pages)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch shell.selection {
        case .chat:
            ChatView(
                viewModel: chatViewModel,
                openChat: shell.openChat,
                newChatNonce: shell.newChatNonce
            )
        case .search:
            SearchView()
        case .library:
            LibraryView()
        case .browser:
            BrowserView()
        case .compare:
            CompareView()
        case .morningBrief:
            MorningBriefView()
        case .deepResearch:
            DeepResearchView()
        case .settings:
            SettingsView()
        }
    }
}

// MARK: - Sidebar

/// Drawer sidebar: New chat, Search, Library, Browser, Pro features,
/// Recents (real SwiftData chat history), Settings, and a Pro card.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var shell: AppShellState
    @StateObject private var store = StoreManager.shared

    @Query(sort: \Chat.createdAt, order: .reverse) private var chats: [Chat]

    var body: some View {
        List {
            Section {
                Button { shell.openNewChat(); hideSidebarIfCompact() } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                Button { select(.search) } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                Button { select(.library) } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                Button { select(.browser) } label: {
                    Label("Browser", systemImage: "globe")
                }
            }

            Section("Pro") {
                Button { select(.compare) } label: {
                    Label("Compare models", systemImage: "square.split.2x2")
                }
                Button { select(.morningBrief) } label: {
                    Label("Morning Brief", systemImage: "sunrise")
                }
                Button { select(.deepResearch) } label: {
                    Label("Deep Research", systemImage: "doc.text.magnifyingglass")
                }
            }

            Section("Recents") {
                if chats.isEmpty {
                    Text("Your chats will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(chats) { chat in
                    Button { openRecent(chat) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(chat.title.isEmpty ? "New Chat" : chat.title)
                                .lineLimit(1)
                            Text(chat.createdAt, style: .relative)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(
                        shell.openChat?.id == chat.id && shell.selection == .chat
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .swipeActions {
                        Button(role: .destructive) {
                            modelContext.delete(chat)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            Section {
                Button { select(.settings) } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("PageMind")
        .safeAreaInset(edge: .bottom) {
            proCard
        }
        .sheet(isPresented: $shell.showingPaywall) {
            PaywallView()
        }
    }

    // MARK: - Sidebar actions

    private func select(_ destination: AppDestination) {
        shell.selection = destination
        hideSidebarIfCompact()
    }

    private func openRecent(_ chat: Chat) {
        shell.openChat(chat)
        hideSidebarIfCompact()
    }

    private func hideSidebarIfCompact() {
        if horizontalSizeClass == .compact {
            shell.columnVisibility = .detailOnly
        }
    }

    // MARK: - Pro card

    /// Free / Pro status at the bottom of the sidebar. PageMind has no
    /// account and no credits system, so this shows only the Pro state.
    private var proCard: some View {
        Button {
            shell.showingPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: store.isPro ? "checkmark.seal.fill" : "sparkles")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isPro ? "PageMind Pro" : "PageMind Free")
                        .font(.subheadline)
                        .bold()
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.isPro
                         ? "Pro is active"
                         : "Browser Agent, Compare, Morning Brief and Deep Research")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(PageMindDesign.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}
