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
    static let cardBackground = Color(uiColor: .tertiarySystemBackground)
    static let rowSpacing: CGFloat = 20
}

// MARK: - Shell state

/// The destinations the sidebar can show.
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
///
/// NOTE: the drawer is plain SwiftUI state (a Boolean + an offset).
/// The first shell used NavigationSplitView and it broke on iPhone:
/// the sidebar took over the whole screen, the large title left a
/// huge empty void at the top, and tapping a row did not reliably
/// show the detail. A custom drawer cannot fail that way — a row tap
/// is just a state change.
@MainActor
final class AppShellState: ObservableObject {
    @Published var selection: AppDestination = .chat
    /// The drawer starts closed: the app opens on Chat, not on a menu.
    @Published var isDrawerOpen = false
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

/// Row button style for the drawer: full-width rows with a real
/// 44pt tap target and press feedback. Plain VStacks have no
/// built-in row styling, so the style carries it.
struct DrawerRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// The leading toolbar button that opens the drawer.
struct SidebarToggleButton: View {
    @EnvironmentObject private var shell: AppShellState

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.25)) {
                shell.isDrawerOpen = true
            }
        } label: {
            Label("Menu", systemImage: "sidebar.leading")
        }
    }
}

// MARK: - App shell

/// Chat-first app shell: the detail view fills the screen and a
/// drawer slides in from the left. Replaces the old four-tab bar
/// (MainTabView) and the NavigationSplitView shell that broke on
/// iPhone.
struct AppShellView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var shell = AppShellState()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var pageContext = PageContextStore()

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Dimmed backdrop: tap anywhere outside the drawer to close it.
                Color.black.opacity(shell.isDrawerOpen ? 0.35 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(shell.isDrawerOpen)
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.25)) {
                            shell.isDrawerOpen = false
                        }
                    }

                SidebarView()
                    .frame(width: min(320, geometry.size.width * 0.85))
                    .frame(maxHeight: .infinity)
                    .background(PageMindDesign.appBackground)
                    .offset(x: shell.isDrawerOpen ? 0 : -min(320, geometry.size.width * 0.85) - 8)
                    .gesture(
                        DragGesture()
                            .onEnded { value in
                                if value.translation.width < -60 {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        shell.isDrawerOpen = false
                                    }
                                }
                            }
                    )
            }
        }
        .animation(.easeOut(duration: 0.25), value: shell.isDrawerOpen)
        .environmentObject(shell)
        .environmentObject(pageContext)
        .onChange(of: pageContext.askRequestID) { _, _ in
            // "Ask about this page" from the Browser tab: jump to Chat.
            shell.selection = .chat
            shell.isDrawerOpen = false
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
///
/// Plain VStack + ScrollView, not a sidebar List: no large title, no
/// floating navigation bar, no safe-area inset. The Pro card is a
/// normal footer view below the scroll area with a solid background,
/// so it can never overlap a row or show one through it.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var shell: AppShellState
    @StateObject private var store = StoreManager.shared

    @Query(sort: \Chat.createdAt, order: .reverse) private var chats: [Chat]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact header — a plain title row, no large-title void.
            HStack {
                Text("PageMind")
                    .font(.title2.bold())
                Spacer()
                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        shell.isDrawerOpen = false
                    }
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    drawerSection {
                        Button { shell.openNewChat(); closeDrawer() } label: {
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

                    Text("Pro")
                        .font(.footnote)
                        .bold()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 4)

                    drawerSection {
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

                    Text("Recents")
                        .font(.footnote)
                        .bold()
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 4)

                    drawerSection {
                        if chats.isEmpty {
                            Text("Your chats will appear here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.vertical, 10)
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
                                .padding(.vertical, 6)
                            }
                            .background(
                                shell.openChat?.id == chat.id && shell.selection == .chat
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .contextMenu {
                                Button(role: .destructive) {
                                    modelContext.delete(chat)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    drawerSection {
                        Button { select(.settings) } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
                .padding(.bottom, 12)
            }

            Divider()

            proCard
        }
        .sheet(isPresented: $shell.showingPaywall) {
            PaywallView()
        }
    }

    // MARK: - Sidebar helpers

    /// One rounded-card section of rows, matching the old look but
    /// laid out by a plain VStack so nothing can overlap it.
    @ViewBuilder
    private func drawerSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .buttonStyle(DrawerRowButtonStyle())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PageMindDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }

    private func select(_ destination: AppDestination) {
        shell.selection = destination
        closeDrawer()
    }

    private func openRecent(_ chat: Chat) {
        shell.openChat(chat)
        closeDrawer()
    }

    private func closeDrawer() {
        withAnimation(.easeOut(duration: 0.25)) {
            shell.isDrawerOpen = false
        }
    }

    // MARK: - Pro card

    /// Free / Pro status at the bottom of the sidebar. PageMind has no
    /// account and no credits system, so this shows only the Pro state.
    /// Solid background, a normal footer view — it never overlaps rows.
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
                        .lineLimit(1)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
