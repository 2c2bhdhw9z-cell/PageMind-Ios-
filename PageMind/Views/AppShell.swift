import SwiftUI
import SwiftData
import UIKit

// MARK: - Shared design tokens

/// The PageMind visual system.
///
/// Modelled on SurfMind's calm look (owner's reference screenshots,
/// 26 Nov 2026): a charcoal background instead of pure black, slightly
/// lighter cards, thin outline icons, regular-weight text, and one
/// accent colour used sparingly. The accent is the app icon's indigo,
/// with the indigo-to-cyan gradient kept for a few hero spots only
/// (send button, logo tile, Upgrade).
///
/// Every colour is explicit and adapts to light and dark mode.
enum PageMindDesign {
    // MARK: Surfaces
    /// Screen background. Dark: charcoal #202023. Light: white.
    static let appBackground = dynamic(dark: 0x202023, light: 0xFFFFFF)
    /// Cards, the composer, grouped rows. Dark #2C2C30, light #F2F2F5.
    static let elevatedCard = dynamic(dark: 0x2C2C30, light: 0xF2F2F5)
    /// Chips and pills that sit on a card or on the background.
    /// Dark #37373C, light #E7E7EC.
    static let subtleCard = dynamic(dark: 0x37373C, light: 0xE7E7EC)
    /// Pressed / selected row fill.
    static let subtleFill = Color.primary.opacity(0.08)
    /// The slide-in menu. Dark #26262A, light #F7F7F9.
    static let drawerBackground = dynamic(dark: 0x26262A, light: 0xF7F7F9)
    /// 1pt outlines around cards.
    static let hairline = Color.primary.opacity(0.07)

    // MARK: Brand — from the app icon
    static let brandIndigo = Color(red: 99 / 255, green: 102 / 255, blue: 241 / 255)
    static let brandIndigoDeep = Color(red: 79 / 255, green: 70 / 255, blue: 229 / 255)
    static let brandCyan = Color(red: 34 / 255, green: 211 / 255, blue: 238 / 255)
    /// Indigo → cyan. Hero spots only.
    static let brandGradient = LinearGradient(
        colors: [brandIndigoDeep, brandIndigo, brandCyan],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Text
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary

    static let rowSpacing: CGFloat = 16

    /// Older name for the card surface, still used by a few screens.
    static let cardBackground = elevatedCard

    private static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            rgb(traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Small icon tile that leads a row (paywall features, library and
/// search rows): accent-coloured outline icon on a soft accent tile.
struct IconChip: View {
    let systemImage: String
    var tint: Color = PageMindDesign.brandIndigo

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// The PageMind logo tile: the app icon's chat bubble on the gradient.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: "text.bubble.fill")
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(PageMindDesign.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// Lays chips out in rows, wrapping to a new row instead of running
/// off the edge of the screen.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            if x > 0 && x + width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let width = min(size.width, bounds.width)
            if x > bounds.minX && x + width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: width, height: size.height)
            )
            x += width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Short, readable model names for chips: "openrouter/free" becomes
/// "Auto (free)", "meta-llama/llama-3.3-70b-instruct:free" becomes
/// "llama-3.3-70b-instruct".
enum ModelDisplayName {
    static func short(_ model: String) -> String {
        if model == "openrouter/free" { return "Auto (free)" }
        var name = model.split(separator: "/").last.map(String.init) ?? model
        if name.hasSuffix(":free") { name.removeLast(5) }
        return name.isEmpty ? model : name
    }

    static func isFree(_ model: String) -> Bool {
        model == "openrouter/free" || model.hasSuffix(":free")
    }
}

// MARK: - Shell state

/// The screens the menu can show.
enum AppDestination: String, Hashable {
    case chat
    case search
    case library
    case browser
    case compare
    case morningBrief
    case deepResearch
}

/// Shared navigation state for the app shell, owned by AppShellView
/// and read by the menu and the screens.
///
/// The menu is plain SwiftUI state (a Boolean + an offset), not
/// NavigationSplitView, which broke on iPhone.
@MainActor
final class AppShellState: ObservableObject {
    @Published var selection: AppDestination = .chat
    /// The menu starts closed: the app opens on Chat.
    @Published var isDrawerOpen = false
    /// The chat the menu asked ChatView to open (nil = no request).
    @Published var openChat: Chat?
    /// Bumped whenever the menu asks for a brand-new chat.
    @Published var newChatNonce = UUID()
    @Published var showingPaywall = false
    /// Settings is a full-height sheet with a close button, the way
    /// SurfMind shows it.
    @Published var showingSettings = false

    func openNewChat() {
        openChat = nil
        newChatNonce = UUID()
        selection = .chat
    }

    func openChat(_ chat: Chat) {
        openChat = chat
        selection = .chat
    }

    func openDrawer() {
        withAnimation(.easeOut(duration: 0.25)) {
            isDrawerOpen = true
        }
    }

    func closeDrawer() {
        withAnimation(.easeOut(duration: 0.25)) {
            isDrawerOpen = false
        }
    }
}

/// The toolbar button that opens the menu, used by the screens that
/// still have a standard navigation bar (Library, Browser, Search,
/// Pro tools).
struct SidebarToggleButton: View {
    @EnvironmentObject private var shell: AppShellState

    var body: some View {
        Button {
            shell.openDrawer()
        } label: {
            Label("Menu", systemImage: "sidebar.leading")
        }
    }
}

/// A plain icon button for PageMind's own top bars: thin icon, 44pt
/// tap target, no glass bubble.
struct TopBarIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(PageMindDesign.primaryText.opacity(0.85))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - App shell

/// Chat-first app shell: the current screen fills the display and a
/// menu slides in from the left.
struct AppShellView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var shell = AppShellState()
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var pageContext = PageContextStore()

    var body: some View {
        GeometryReader { geometry in
            let drawerWidth = min(330, geometry.size.width * 0.82)
            ZStack(alignment: .leading) {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Dimmed backdrop: tap anywhere outside the menu to close it.
                Color.black.opacity(shell.isDrawerOpen ? 0.5 : 0)
                    .ignoresSafeArea()
                    .allowsHitTesting(shell.isDrawerOpen)
                    .onTapGesture {
                        shell.closeDrawer()
                    }

                SidebarView()
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity)
                    .background(PageMindDesign.drawerBackground.ignoresSafeArea())
                    .offset(x: shell.isDrawerOpen ? 0 : -drawerWidth - 8)
                    .gesture(
                        DragGesture()
                            .onEnded { value in
                                if value.translation.width < -60 {
                                    shell.closeDrawer()
                                }
                            }
                    )
            }
        }
        .background(PageMindDesign.appBackground.ignoresSafeArea())
        .animation(.easeOut(duration: 0.25), value: shell.isDrawerOpen)
        .environmentObject(shell)
        .environmentObject(pageContext)
        .sheet(isPresented: $shell.showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $shell.showingPaywall) {
            PaywallView()
        }
        .onChange(of: pageContext.askRequestID) { _, _ in
            // "Ask about this page" from the Browser: jump to Chat.
            shell.selection = .chat
            shell.isDrawerOpen = false
        }
        .task {
            // Import pages saved from the Share / Safari extensions
            // while the app was not running.
            PendingPageImporter.importPendingPages(modelContext: modelContext)
            let pages = (try? modelContext.fetch(FetchDescriptor<SavedPage>())) ?? []
            WidgetDataWriter.writeSnapshot(pages: pages)
            #if DEBUG
            applyScreenshotScreen()
            #endif
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
        }
    }

    #if DEBUG
    /// Opens the screen named by `-uiShot` (CI screenshots only).
    private func applyScreenshotScreen() {
        guard let screen = ScreenshotMode.screen else { return }
        switch screen {
        case "drawer": shell.isDrawerOpen = true
        case "search": shell.selection = .search
        case "library": shell.selection = .library
        case "browser": shell.selection = .browser
        case "compare": shell.selection = .compare
        case "brief": shell.selection = .morningBrief
        case "research": shell.selection = .deepResearch
        case "settings": shell.showingSettings = true
        case "paywall": shell.showingPaywall = true
        case "conversation":
            chatViewModel.messages = [
                ChatMessage(role: "user", content: "Summarize this article in three points."),
                ChatMessage(
                    role: "assistant",
                    content: """
                    ## The short version
                    The article argues that **on-device AI** is about to change how phones handle reading.

                    - Pages are summarized *without* leaving the browser.
                    - Your saved pages become a searchable memory.
                    - Free models are now good enough for most questions.

                    Want me to compare it with another source?
                    """,
                    citationsJSON: #"[{"title":"The Verge — On-device AI","url":"https://www.theverge.com"},{"title":"Apple Newsroom","url":"https://www.apple.com/newsroom"}]"#
                ),
                ChatMessage(role: "user", content: "Yes, compare it with Apple's announcement."),
            ]
        default: break
        }
    }
    #endif
}

// MARK: - Menu (sidebar)

/// Slide-in menu, laid out like SurfMind's: logo header, plain rows
/// (New chat, Search, Library, Browser), the Pro tools, Recents, and a
/// Settings / plan pill pinned at the bottom.
struct SidebarView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var shell: AppShellState
    @StateObject private var store = StoreManager.shared

    @Query(sort: \Chat.createdAt, order: .reverse) private var chats: [Chat]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("PageMind")
                    .font(.system(size: 19, weight: .semibold))
                Spacer()
                TopBarIconButton(systemImage: "sidebar.leading", accessibilityLabel: "Close menu") {
                    shell.closeDrawer()
                }
            }
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .padding(.top, 6)
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    menuRow("New chat", systemImage: "plus", isSelected: false) {
                        shell.openNewChat()
                        shell.closeDrawer()
                    }
                    destinationRow("Search", systemImage: "magnifyingglass", destination: .search)
                    destinationRow("Library", systemImage: "books.vertical", destination: .library)
                    destinationRow("Browser", systemImage: "globe", destination: .browser)

                    sectionHeader("Tools")
                    destinationRow("Deep Research", systemImage: "doc.text.magnifyingglass", destination: .deepResearch, isPro: true)
                    destinationRow("Compare models", systemImage: "rectangle.split.2x1", destination: .compare, isPro: true)
                    destinationRow("Morning Brief", systemImage: "sunrise", destination: .morningBrief, isPro: true)

                    sectionHeader("Recents")
                    if chats.isEmpty {
                        Text("Your chats will appear here.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                    ForEach(chats) { chat in
                        recentRow(chat)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)

            settingsPill
        }
    }

    // MARK: Rows

    private func destinationRow(
        _ title: String,
        systemImage: String,
        destination: AppDestination,
        isPro: Bool = false
    ) -> some View {
        menuRow(
            title,
            systemImage: systemImage,
            isSelected: shell.selection == destination,
            showsProTag: isPro && !store.isPro
        ) {
            shell.selection = destination
            shell.closeDrawer()
        }
    }

    private func menuRow(
        _ title: String,
        systemImage: String,
        isSelected: Bool,
        showsProTag: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                Spacer()
                if showsProTag {
                    Text("PRO")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(PageMindDesign.brandIndigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(PageMindDesign.brandIndigo.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(PageMindDesign.primaryText)
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? PageMindDesign.subtleFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ chat: Chat) -> some View {
        let isOpen = shell.openChat?.id == chat.id && shell.selection == .chat
        return Button {
            shell.openChat(chat)
            shell.closeDrawer()
        } label: {
            Text(chat.title.isEmpty ? "New chat" : chat.title)
                .font(.system(size: 15))
                .lineLimit(1)
                .foregroundStyle(PageMindDesign.primaryText.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isOpen ? PageMindDesign.subtleFill : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                modelContext.delete(chat)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 18)
            .padding(.bottom, 4)
    }

    // MARK: Settings pill

    /// Bottom pill: Settings plus the current plan, with an Upgrade
    /// button while on the free plan. PageMind has no account, so the
    /// pill shows the plan instead of a user name.
    private var settingsPill: some View {
        HStack(spacing: 10) {
            Button {
                shell.showingSettings = true
                shell.closeDrawer()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(PageMindDesign.primaryText)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(PageMindDesign.subtleCard))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Settings")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(PageMindDesign.primaryText)
                        Text(store.isPro ? "Pro plan" : "Free plan")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !store.isPro {
                Button {
                    shell.showingPaywall = true
                } label: {
                    Text("Upgrade")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(PageMindDesign.brandGradient)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PageMindDesign.elevatedCard)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
