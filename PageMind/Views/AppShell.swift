import SwiftUI
import SwiftData

// MARK: - Shared design tokens

/// The PageMind visual system.
///
/// Brand comes from the app icon: an indigo gradient page with a cyan
/// chat bubble. Indigo (#4F46E5 family) to cyan is the hero gradient;
/// indigo is the accent everywhere else. Surfaces are deliberate, not
/// the old "secondarySystemBackground everywhere" that read as a
/// default settings screen:
///
/// - Dark mode: true black app background, elevated cards in dark grey.
/// - Light mode: white app background, elevated cards in light grey.
///
/// All brand colour is explicit in code (never `Color.accentColor`),
/// so the look does not depend on the AccentColor asset resolving.
enum PageMindDesign {
    // MARK: Surfaces
    /// True system background: black in dark mode, white in light mode.
    static let appBackground = Color(uiColor: .systemBackground)
    /// Raised card surface: #1C1C1E in dark mode, #F2F2F7 in light mode.
    static let elevatedCard = Color(uiColor: .secondarySystemBackground)
    /// Recessed surface inside a card (text fields, chips on cards).
    static let subtleCard = Color(uiColor: .tertiarySystemBackground)
    /// Translucent fill for pills and chips sitting on the background.
    static let subtleFill = Color.primary.opacity(0.08)

    // MARK: Brand — from the app icon
    static let brandIndigo = Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
    static let brandIndigoDeep = Color(red: 67 / 255, green: 56 / 255, blue: 202 / 255)
    static let brandCyan = Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255)
    /// Indigo → cyan, top-leading to bottom-trailing. Hero elements only
    /// (logo tile, Pro card, primary buttons, active filter pills).
    static let brandGradient = LinearGradient(
        colors: [brandIndigoDeep, brandIndigo, brandCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Text
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary

    static let rowSpacing: CGFloat = 20

    /// Kept for the few call sites that still say `cardBackground`:
    /// it is the elevated card surface.
    static let cardBackground = elevatedCard
}

/// iOS Settings-style icon chip: a small rounded square with a white
/// glyph on the brand colour. Used wherever an icon leads a row
/// (sidebar, paywall features, library/search rows).
struct IconChip: View {
    let systemImage: String
    var tint: Color = PageMindDesign.brandIndigo

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }
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
            .background(configuration.isPressed ? PageMindDesign.subtleFill : Color.clear)
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
                // Dark enough that the detail behind reads as dimmed, not
                // as text showing through next to the drawer.
                Color.black.opacity(shell.isDrawerOpen ? 0.55 : 0)
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
            // Compact header: gradient logo tile + wordmark, no
            // large-title void.
            HStack(spacing: 10) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(PageMindDesign.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
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
                            drawerRow("New chat", systemImage: "square.and.pencil")
                        }
                        Button { select(.search) } label: {
                            drawerRow("Search", systemImage: "magnifyingglass")
                        }
                        Button { select(.library) } label: {
                            drawerRow("Library", systemImage: "books.vertical")
                        }
                        Button { select(.browser) } label: {
                            drawerRow("Browser", systemImage: "globe")
                        }
                    }

                    Text("PRO")
                        .font(.footnote)
                        .bold()
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 4)

                    drawerSection {
                        Button { select(.compare) } label: {
                            drawerRow("Compare models", systemImage: "square.split.2x2")
                        }
                        Button { select(.morningBrief) } label: {
                            drawerRow("Morning Brief", systemImage: "sunrise")
                        }
                        Button { select(.deepResearch) } label: {
                            drawerRow("Deep Research", systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    Text("RECENTS")
                        .font(.footnote)
                        .bold()
                        .tracking(0.8)
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
                                    ? PageMindDesign.brandIndigo.opacity(0.15)
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
                            drawerRow("Settings", systemImage: "gearshape")
                        }
                    }
                }
                .padding(.bottom, 24)
            }

            Divider()

            proCard
        }
        .sheet(isPresented: $shell.showingPaywall) {
            PaywallView()
        }
    }

    // MARK: - Sidebar helpers

    /// One drawer row: brand icon chip + label. The chip is what
    /// makes the sidebar read as designed instead of a plain list.
    private func drawerRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            IconChip(systemImage: systemImage)
            Text(title)
                .font(.body)
                .foregroundStyle(PageMindDesign.primaryText)
        }
    }

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
    /// A designed gradient card (indigo → cyan, white text) — the
    /// footer's hero element, not a grey box. Solid gradient, a normal
    /// footer view — it never overlaps rows.
    private var proCard: some View {
        Button {
            shell.showingPaywall = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: store.isPro ? "checkmark.seal.fill" : "sparkles")
                    .font(.title3)
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.isPro ? "PageMind Pro" : "PageMind Free")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(store.isPro
                         ? "Pro is active"
                         : "Browser Agent, Compare, Morning Brief and Deep Research")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(14)
            .background(PageMindDesign.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: PageMindDesign.brandIndigo.opacity(0.35), radius: 12, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
