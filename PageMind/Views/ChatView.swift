import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

/// The chat screen, laid out like SurfMind's: a plain top bar (menu,
/// title, share, new chat), a centred greeting with the model chip and
/// the message box underneath on the empty screen, and the same message
/// box pinned to the bottom once a conversation starts.
struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    // The single app-level settings instance, injected by PageMindApp.
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pageContext: PageContextStore
    @EnvironmentObject private var shell: AppShellState

    @Query(sort: \SavedPage.savedAt, order: .reverse) private var savedPages: [SavedPage]

    /// The view model is owned by the app shell (AppShellView) so the
    /// conversation survives switching to another screen and back.
    /// `openChat` / `newChatNonce` are how the menu drives this view:
    /// open a recent chat, or start a fresh one.
    @ObservedObject private var viewModel: ChatViewModel
    private let openChat: Chat?
    private let newChatNonce: UUID

    @StateObject private var catalog = ModelCatalog()

    @State private var draft = ""
    @State private var showAttachSheet = false
    @State private var attachedPages: [SavedPage] = []
    @State private var showPDFImporter = false
    @State private var attachedPDFTexts: [String] = []
    @State private var attachedPDFNames: [String] = []
    @State private var attachedImages: [ChatImageAttachment] = []
    @State private var showPhotoPicker = false
    @State private var photoPickerItems: [PhotosPickerItem] = []
    @State private var useWebSearch = false
    @State private var useWebFetch = false
    /// What the chat is doing right now ("Searching the web…"), shown
    /// under the message box while a page is fetched or a search runs.
    @State private var statusText: String?
    @State private var showSettingsSheet = false
    @State private var showModelPicker = false
    @State private var modelSearchText = ""
    /// Whether the message box has the keyboard. Tapping outside a text
    /// field, dragging the chat, or the keyboard button all set it false.
    @FocusState private var composerFocused: Bool

    init(viewModel: ChatViewModel, openChat: Chat? = nil, newChatNonce: UUID = UUID()) {
        self.viewModel = viewModel
        self.openChat = openChat
        self.newChatNonce = newChatNonce
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topBar

                if viewModel.messages.isEmpty {
                    homeView
                } else {
                    messageList
                    errorBanner
                    statusLine
                    VStack(spacing: 8) {
                        controlsRow
                        attachedItemsBar
                        composerCard
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
            }
            .background(PageMindDesign.appBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAttachSheet) {
                attachPageSheet
            }
            .sheet(isPresented: $showModelPicker) {
                modelPickerSheet
            }
            .fileImporter(
                isPresented: $showPDFImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: true
            ) { result in
                importPDFs(result)
            }
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $photoPickerItems,
                maxSelectionCount: VisionImagePrep.maxImagesPerChat,
                matching: .images
            )
            // Count-based trigger: PhotosPickerItem is not guaranteed
            // Equatable across SDKs, so the count is the change key.
            .onChange(of: photoPickerItems.count) { _, _ in
                Task { await importPhotos(photoPickerItems) }
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView(startPage: .apiKeys)
            }
            .onAppear {
                viewModel.configure(with: settings)
                openRequestedChatIfNeeded()
                Task {
                    _ = await catalog.fetchOpenRouterModels()
                }
                #if DEBUG
                if ScreenshotMode.screen == "keyboard" {
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        composerFocused = true
                    }
                }
                #endif
            }
            // The menu asked to open a recent chat.
            .onChange(of: openChat?.id) { _, _ in
                openRequestedChatIfNeeded()
            }
            // The menu asked for a brand-new chat.
            .onChange(of: newChatNonce) { _, _ in
                startNewChat()
            }
            // Reconfigure when the provider or model changes in Settings
            // (the view model holds its own provider + model copies).
            .onChange(of: settings.selectedProviderRaw) { _, _ in
                viewModel.configure(with: settings)
            }
            .onChange(of: settings.selectedModel) { _, _ in
                viewModel.configure(with: settings)
            }
            .onChange(of: pageContext.askRequestID) { _, _ in
                attachPendingPage()
            }
        }
    }

    // MARK: - Top bar

    /// Plain top bar like SurfMind's: menu button and chat title on the
    /// left, share (once there is a conversation) and new chat on the
    /// right. No large title, no glass bubbles.
    private var topBar: some View {
        HStack(spacing: 0) {
            TopBarIconButton(systemImage: "sidebar.leading", accessibilityLabel: "Open menu") {
                composerFocused = false
                shell.openDrawer()
            }
            Text(chatTitle)
                .font(.headline)
                .lineLimit(1)
                .padding(.leading, 2)
            Spacer(minLength: 8)
            if !viewModel.messages.isEmpty {
                ShareLink(item: conversationText) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(PageMindDesign.primaryText.opacity(0.85))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Share this chat")
            }
            TopBarIconButton(systemImage: "square.and.pencil", accessibilityLabel: "New chat") {
                startNewChat()
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 50)
    }

    private var chatTitle: String {
        guard !viewModel.messages.isEmpty,
              let title = viewModel.currentChat?.title,
              !title.isEmpty else { return "New chat" }
        return title
    }

    /// The whole conversation as plain text, for the share button.
    private var conversationText: String {
        viewModel.messages
            .map { ($0.role == "user" ? "You: " : "PageMind: ") + $0.content }
            .joined(separator: "\n\n")
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if viewModel.isStreaming {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Thinking…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(.red)
                if let hint = viewModel.errorHint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if error.contains("No API key") || error.contains("401") {
                    Button("Add or check the API key in Settings") {
                        showSettingsSheet = true
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(PageMindDesign.brandIndigo)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.red.opacity(0.1))
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let statusText {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Empty chat (home)

    /// Time-aware greeting, like SurfMind's "Good evening 🌙".
    private var greetingLine: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning ☀️"
        case 12..<17: return "Good afternoon 🌤️"
        default: return "Good evening 🌙"
        }
    }

    /// The empty chat: greeting centred on the screen, the model chip
    /// and message box right under it, then shortcuts to the things
    /// PageMind can read.
    private var homeView: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    Text(greetingLine)
                        .font(.title)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)

                    VStack(spacing: 10) {
                        controlsRow
                        attachedItemsBar
                        composerCard
                    }

                    statusLine

                    suggestionChips

                    if needsAPIKey {
                        keyNudge
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var suggestionChips: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            suggestionChip("Summarize a saved page", systemImage: "doc.text") {
                showAttachSheet = true
            }
            suggestionChip("Search the web", systemImage: "globe") {
                useWebSearch = true
                composerFocused = true
            }
            suggestionChip("Chat with a PDF", systemImage: "doc.richtext") {
                showPDFImporter = true
            }
            suggestionChip("Ask about a photo", systemImage: "photo") {
                showPhotoPicker = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
            }
            .font(.subheadline)
            .foregroundStyle(PageMindDesign.primaryText.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var needsAPIKey: Bool {
        settings.apiKey(for: settings.selectedProvider) == nil
            && settings.selectedProvider.requiresKey
    }

    /// Shown until an AI key is saved: one tap opens Settings straight
    /// on the API keys page.
    private var keyNudge: some View {
        Button {
            showSettingsSheet = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "key")
                    .font(.system(size: 16))
                    .foregroundStyle(PageMindDesign.brandIndigo)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(PageMindDesign.brandIndigo.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add a free AI key to start")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PageMindDesign.primaryText)
                    Text("OpenRouter has free models. It takes about two minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(PageMindDesign.elevatedCard)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Model chip row

    /// Model chip and the VS (compare) chip, like SurfMind's row above
    /// its message box, plus a "Free" tag when the model costs nothing.
    private var controlsRow: some View {
        HStack(spacing: 8) {
            Button {
                composerFocused = false
                showModelPicker = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PageMindDesign.brandIndigo)
                    Text(ModelDisplayName.short(viewModel.selectedModel))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PageMindDesign.primaryText)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(PageMindDesign.elevatedCard))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model: \(viewModel.selectedModel)")

            Button {
                composerFocused = false
                shell.selection = .compare
            } label: {
                Text("VS")
                    .font(.footnote.weight(.heavy))
                    .italic()
                    .foregroundStyle(PageMindDesign.primaryText)
                    .frame(width: 42, height: 34)
                    .background(Capsule().fill(PageMindDesign.elevatedCard))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Compare two models")

            Spacer(minLength: 0)

            if ModelDisplayName.isFree(viewModel.selectedModel) {
                Text("Free")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().stroke(Color.green.opacity(0.5), lineWidth: 1))
            }
        }
    }

    /// Model picker: search box, a Favorites section with a star toggle
    /// per model (persisted in AppSettings), then the provider's models,
    /// each with capability badges drawn from the provider data that
    /// actually exists — "Free" for free models, "Vision" when the
    /// current provider takes image input.
    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                if !favoriteModels.isEmpty {
                    Section("Favorites") {
                        ForEach(favoriteModels, id: \.self) { model in
                            modelRow(model)
                        }
                    }
                    .listRowBackground(PageMindDesign.elevatedCard)
                }
                Section {
                    ForEach(filteredModels, id: \.self) { model in
                        modelRow(model)
                    }
                } header: {
                    Text(settings.selectedProvider.displayName)
                } footer: {
                    Text("Free models come from OpenRouter. The model you pick is used for the next reply. Vision means this provider accepts photos.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(PageMindDesign.elevatedCard)
                Section {
                    Button("Refresh model list") {
                        Task { _ = await catalog.fetchOpenRouterModels() }
                    }
                    .foregroundStyle(PageMindDesign.brandIndigo)
                }
                .listRowBackground(PageMindDesign.elevatedCard)
            }
            .scrollContentBackground(.hidden)
            .background(PageMindDesign.appBackground)
            .searchable(text: $modelSearchText, prompt: "Search models")
            .navigationTitle("Choose a model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showModelPicker = false }
                }
            }
        }
    }

    /// One model row: tap to select, star to favourite. The star is a
    /// separate button so it never triggers the select action.
    private func modelRow(_ model: String) -> some View {
        HStack(spacing: 8) {
            Button {
                settings.selectedModel = model
                showModelPicker = false
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ModelDisplayName.short(model))
                            .font(.body)
                            .lineLimit(1)
                        Text(model)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            if ModelDisplayName.isFree(model) {
                                capabilityBadge("Free")
                            }
                            if viewModel.providerSupportsVision {
                                capabilityBadge("Vision")
                            }
                        }
                    }
                    Spacer()
                    if model == viewModel.selectedModel {
                        Image(systemName: "checkmark")
                            .foregroundStyle(PageMindDesign.brandIndigo)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                settings.toggleFavoriteModel(model)
            } label: {
                Image(systemName: settings.favoriteModels.contains(model) ? "star.fill" : "star")
                    .foregroundStyle(
                        settings.favoriteModels.contains(model) ? .yellow : .secondary
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                settings.favoriteModels.contains(model) ? "Remove \(model) from favorites" : "Add \(model) to favorites"
            )
        }
    }

    private func capabilityBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .bold()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(PageMindDesign.brandIndigo.opacity(0.15))
            .foregroundStyle(PageMindDesign.brandIndigo)
            .clipShape(Capsule())
    }

    /// Starred models first (search-filtered when searching).
    private var favoriteModels: [String] {
        let favorites = availableModels.filter { settings.favoriteModels.contains($0) }
        guard !modelSearchText.isEmpty else { return favorites }
        return favorites.filter { $0.localizedCaseInsensitiveContains(modelSearchText) }
    }

    /// Non-favourite models, search-filtered when searching.
    private var filteredModels: [String] {
        var models = availableModels.filter { !settings.favoriteModels.contains($0) }
        if !modelSearchText.isEmpty {
            models = models.filter { $0.localizedCaseInsensitiveContains(modelSearchText) }
        }
        return models
    }

    // MARK: - Attachments + message box

    private var hasAttachments: Bool {
        !attachedPages.isEmpty || !attachedPDFNames.isEmpty || !attachedImages.isEmpty
    }

    /// Attached pages, PDFs and photos as removable chips that wrap onto
    /// new lines instead of running off the screen.
    @ViewBuilder
    private var attachedItemsBar: some View {
        if hasAttachments {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(attachedPages) { page in
                        attachmentChip(page.title.isEmpty ? page.url : page.title, systemImage: "doc.text") {
                            attachedPages.removeAll { $0.id == page.id }
                        }
                    }
                    ForEach(Array(attachedPDFNames.enumerated()), id: \.offset) { index, name in
                        attachmentChip(name, systemImage: "doc.richtext") {
                            guard index < attachedPDFNames.count else { return }
                            attachedPDFTexts.remove(at: index)
                            attachedPDFNames.remove(at: index)
                        }
                    }
                    ForEach(attachedImages) { image in
                        attachmentChip(image.fileName, systemImage: "photo") {
                            attachedImages.removeAll { $0.id == image.id }
                        }
                    }
                }
                if !attachedImages.isEmpty && !viewModel.providerSupportsVision {
                    Text("This provider can't read photos, so the photo will be ignored. Switch to OpenAI, Anthropic, Gemini or a vision model.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func attachmentChip(_ title: String, systemImage: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(PageMindDesign.brandIndigo)
            Text(title)
                .lineLimit(1)
                .frame(maxWidth: 190, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(PageMindDesign.subtleFill))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title)")
        }
        .font(.footnote)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(PageMindDesign.subtleCard))
    }

    /// The message box: a rounded card with the text field on top and
    /// a row of small controls underneath — "+" (photo, PDF, Library,
    /// web fetch), the web search globe, a hide-keyboard button while
    /// typing, and the send / stop button.
    private var composerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask PageMind anything…", text: $draft, axis: .vertical)
                .font(.body)
                .lineLimit(1...6)
                .focused($composerFocused)
                .disabled(viewModel.isStreaming)

            HStack(spacing: 4) {
                plusMenu
                webSearchButton
                if useWebFetch {
                    Text("Reads links")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PageMindDesign.brandIndigo)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(PageMindDesign.brandIndigo.opacity(0.15)))
                }
                Spacer(minLength: 0)
                if composerFocused {
                    Button {
                        composerFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .frame(width: 38, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide keyboard")
                }
                sendButton
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(PageMindDesign.elevatedCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(PageMindDesign.hairline, lineWidth: 1)
        )
    }

    /// Everything that can be added to a message, in one menu.
    private var plusMenu: some View {
        Menu {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Attach photo", systemImage: "photo")
            }
            .disabled(attachedImages.count >= VisionImagePrep.maxImagesPerChat)

            Button {
                showPDFImporter = true
            } label: {
                Label("Attach file (PDF)", systemImage: "doc.fill")
            }

            Button {
                showAttachSheet = true
            } label: {
                Label("Add from Library", systemImage: "books.vertical")
            }

            Divider()

            Toggle("Web search", isOn: $useWebSearch)
            Toggle("Read links in my message", isOn: $useWebFetch)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Add to message")
    }

    private var webSearchButton: some View {
        Button {
            useWebSearch.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "globe")
                    .font(.system(size: 16))
                if useWebSearch {
                    Text("Search")
                        .font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(useWebSearch ? PageMindDesign.brandIndigo : .secondary)
            .padding(.horizontal, useWebSearch ? 10 : 0)
            .frame(minWidth: 36, minHeight: 32)
            .background(
                Capsule().fill(useWebSearch ? PageMindDesign.brandIndigo.opacity(0.15) : Color.clear)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(useWebSearch ? "Web search is on" : "Web search is off")
    }

    @ViewBuilder
    private var sendButton: some View {
        if viewModel.isStreaming {
            Button {
                viewModel.cancelStreaming()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(PageMindDesign.appBackground)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(PageMindDesign.primaryText))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop")
        } else {
            let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button {
                sendDraft()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle().fill(
                            canSend
                                ? AnyShapeStyle(PageMindDesign.brandGradient)
                                : AnyShapeStyle(PageMindDesign.subtleCard)
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    // MARK: - Attach sheet

    private var attachPageSheet: some View {
        NavigationStack {
            List {
                if savedPages.isEmpty {
                    Text("No saved pages yet. Save a page from the Browser tab first.")
                        .foregroundStyle(.secondary)
                }
                ForEach(savedPages) { page in
                    Button {
                        if !attachedPages.contains(where: { $0.id == page.id }) {
                            attachedPages.append(page)
                        }
                        showAttachSheet = false
                    } label: {
                        VStack(alignment: .leading) {
                            Text(page.title.isEmpty ? page.url : page.title)
                                .lineLimit(1)
                            Text(page.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("Attach a page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAttachSheet = false }
                }
            }
        }
    }

    // MARK: - Actions

    /// Clears the current conversation and any pending attachments.
    /// Used by the toolbar button and by the sidebar's New chat.
    private func startNewChat() {
        viewModel.newChat()
        attachedPages = []
        attachedPDFTexts = []
        attachedPDFNames = []
        attachedImages = []
    }

    /// Binds the chat the sidebar asked for, if any and if it is not
    /// already the open one. Called on appear and when `openChat` changes.
    private func openRequestedChatIfNeeded() {
        guard let chat = openChat, viewModel.currentChat?.id != chat.id else { return }
        viewModel.bind(chat: chat, modelContext: modelContext)
    }

    private var availableModels: [String] {
        // Live OpenRouter list when fetched, otherwise the free fallback list.
        let live = catalog.openRouterModels
        if catalog.lastFetchSucceeded, !live.isEmpty {
            return live
        }
        return ModelCatalog.fallbackFreeModels
    }

    private func attachPendingPage() {
        guard let page = pageContext.takePendingPage() else { return }
        if !attachedPages.contains(where: { $0.id == page.id }) {
            attachedPages.append(page)
        }
    }

    /// Imports picked photos as vision attachments (max 4 per chat).
    /// Each photo is downsized and re-encoded as JPEG on-device; unreadable
    /// images are skipped. A vision-capable model is required — if the
    /// current model is text-only, the provider returns an error and the
    /// chat shows it with a hint.
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        defer { photoPickerItems = [] }
        for item in items {
            guard attachedImages.count < VisionImagePrep.maxImagesPerChat else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let jpeg = VisionImagePrep.prepare(data) else { continue }
            attachedImages.append(ChatImageAttachment(
                fileName: "Photo \(attachedImages.count + 1)",
                jpegData: jpeg
            ))
        }
    }

    /// Imports picked PDFs as chat context (max 10 per chat, per spec).
    /// Text is extracted on-device with PDFKit; unreadable or empty PDFs
    /// are skipped silently.
    private func importPDFs(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        let extractor = PDFTextExtractor()
        for url in urls {
            guard attachedPDFTexts.count < 10 else { break }
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }
            guard let data = try? Data(contentsOf: url) else { continue }
            let text = extractor.extractText(from: data)
            guard !text.isEmpty else { continue }
            attachedPDFTexts.append(text)
            attachedPDFNames.append(url.lastPathComponent)
        }
    }

    private func sendDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        draft = ""

        if viewModel.currentChat == nil {
            let chat = Chat(title: String(prompt.prefix(60)))
            modelContext.insert(chat)
            viewModel.bind(chat: chat, modelContext: modelContext)
        }

        // Web fetch and web search both run before the reply, with a
        // status line above the composer narrating each step. The fetch
        // reads the first http(s) URL in the message and attaches its
        // readable text as context; with no URL in the message it does
        // nothing. Failures are silent — the chat proceeds without the
        // extra context instead of erroring out.
        Task {
            var fetchedTexts: [String] = []
            if useWebFetch, let url = Self.firstURL(in: prompt) {
                statusText = "Fetching \(url.host ?? url.absoluteString)…"
                if let text = await Self.fetchPageText(url: url) {
                    fetchedTexts.append(text)
                }
                statusText = nil
            }

            var webResults: [SourceCitation] = []
            if useWebSearch {
                statusText = "Searching the web…"
                webResults = await WebSearchService().search(
                    query: prompt,
                    braveAPIKey: settings.braveAPIKey
                )
                statusText = nil
            }

            viewModel.send(
                prompt: prompt,
                contextPages: attachedPages,
                attachments: attachedPDFTexts + fetchedTexts,
                webSearchResults: webResults,
                imageAttachments: attachedImages
            )
        }
    }

    /// The first http(s) URL in a message, if any. Trailing punctuation
    /// (periods, commas, closing brackets) is stripped so a URL at the
    /// end of a sentence still parses.
    private static func firstURL(in text: String) -> URL? {
        for token in text.split(separator: " ") {
            var candidate = String(token)
            while let last = candidate.last, ".,;:!?)]}".contains(last) {
                candidate.removeLast()
            }
            guard candidate.hasPrefix("http://") || candidate.hasPrefix("https://"),
                  let url = URL(string: candidate),
                  url.host != nil else { continue }
            return url
        }
        return nil
    }

    /// Fetches a page over URLSession and extracts its readable text with
    /// the same Swift fallback the Reader uses. Returns nil on any
    /// failure (network, non-HTML, empty text) — the caller proceeds
    /// without the fetched context.
    private static func fetchPageText(url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        let extracted = ReaderExtractor.extractReaderText(html: html)
        let text = extracted.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let title = extracted.title.isEmpty ? url.host ?? url.absoluteString : extracted.title
        return "Fetched page \"\(title)\" (\(url.absoluteString)):\n\(String(text.prefix(6000)))"
    }
}

// MARK: - Message row

/// One message. Yours sit on the right in a rounded bubble; PageMind's
/// answers use the full width with no bubble, followed by numbered
/// source chips and copy / share buttons, the way modern chat apps
/// (and SurfMind) show them.
private struct MessageRow: View {
    let message: ChatMessage
    @State private var copied = false

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 56)
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(PageMindDesign.elevatedCard)
                    )
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                MarkdownText(content: message.content)

                if !message.citations.isEmpty {
                    sources
                }

                HStack(spacing: 2) {
                    Button {
                        UIPasteboard.general.string = message.content
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(copied ? "Copied" : "Copy answer")

                    ShareLink(item: message.content) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, height: 30)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Share answer")
                }
                .padding(.leading, -8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Numbered source chips; tapping one opens the page.
    private var sources: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array(message.citations.enumerated()), id: \.offset) { index, citation in
                if let url = URL(string: citation.url) {
                    Link(destination: url) {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(PageMindDesign.brandIndigo))
                            Text(citation.title.isEmpty ? (url.host ?? citation.url) : citation.title)
                                .font(.footnote)
                                .lineLimit(1)
                                .frame(maxWidth: 220, alignment: .leading)
                        }
                        .foregroundStyle(PageMindDesign.primaryText)
                        .padding(.leading, 5)
                        .padding(.trailing, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(PageMindDesign.elevatedCard))
                    }
                }
            }
        }
    }
}

// MARK: - Markdown

/// Shows the Markdown that AI models write: headings, bullet and
/// numbered lists, quotes, code blocks, and inline bold, italic, code
/// and links. SwiftUI's Text only understands inline Markdown and runs
/// paragraphs and list items together, so blocks are split out here.
struct MarkdownText: View {
    let content: String

    private enum Block {
        case heading(String, level: Int)
        case bullet(String)
        case numbered(String, text: String)
        case quote(String)
        case code(String)
        case paragraph(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Self.blocks(from: content).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let text, let level):
            Self.inline(text)
                .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                Self.inline(text)
                    .font(.body)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Self.inline(text)
                    .font(.body)
            }
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(PageMindDesign.brandIndigo.opacity(0.6))
                    .frame(width: 3)
                Self.inline(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PageMindDesign.elevatedCard)
            )
        case .paragraph(let text):
            Self.inline(text)
                .font(.body)
        }
    }

    /// Inline Markdown (bold, italic, `code`, links) with line breaks kept.
    private static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    private static func blocks(from content: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph = []
            }
        }

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                continue
            }
            if inCode {
                codeLines.append(rawLine)
                continue
            }
            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = line.dropFirst(level)
                if level <= 6, rest.hasPrefix(" ") {
                    let text = rest.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty {
                        flushParagraph()
                        blocks.append(.heading(text, level: level))
                        continue
                    }
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(of: "."),
               dot > line.startIndex,
               line[line.startIndex..<dot].allSatisfy(\.isNumber),
               line[line.index(after: dot)...].hasPrefix(" ") {
                flushParagraph()
                let textStart = line.index(dot, offsetBy: 2)
                blocks.append(.numbered(String(line[...dot]), text: String(line[textStart...])))
                continue
            }
            paragraph.append(line)
        }
        // An answer still streaming in can end inside a code block.
        if inCode, !codeLines.isEmpty {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks
    }
}
