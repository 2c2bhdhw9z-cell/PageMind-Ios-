import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI

struct ChatView: View {
    @Environment(\.modelContext) private var modelContext
    // The single app-level settings instance, injected by PageMindApp.
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var pageContext: PageContextStore

    @Query(sort: \SavedPage.savedAt, order: .reverse) private var savedPages: [SavedPage]

    /// The view model is owned by the app shell (AppShellView) so the
    /// conversation survives switching to another sidebar destination
    /// and back. `openChat` / `newChatNonce` are how the sidebar drives
    /// this view: open a recent chat, or start a fresh one.
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
    /// What the chat is doing right now, shown above the composer while
    /// a page is being fetched or a web search is running — the same
    /// narration pattern SurfMind uses ("Reading…", "Searching…").
    @State private var statusText: String?
    @State private var showSettingsSheet = false
    @State private var showModelPicker = false
    @State private var modelSearchText = ""

    init(viewModel: ChatViewModel, openChat: Chat? = nil, newChatNonce: UUID = UUID()) {
        self.viewModel = viewModel
        self.openChat = openChat
        self.newChatNonce = newChatNonce
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if viewModel.messages.isEmpty {
                    // Chat-first home: greeting, model picker, composer.
                    homeView
                } else {
                    messageList

                    if let error = viewModel.errorMessage {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                            if let hint = viewModel.errorHint {
                                Text(hint)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if error.contains("No API key") || error.contains("401") {
                                Button("Add or check the API key in Settings") {
                                    showSettingsSheet = true
                                }
                                .font(.footnote)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                    }

                    if let statusText {
                        HStack {
                            ProgressView()
                            Text(statusText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }

                    attachedPagesBar
                    composer
                }
            }
            .background(PageMindDesign.appBackground)
            .navigationTitle(viewModel.currentChat?.title ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarToggleButton()
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        startNewChat()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                }
            }
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
                SettingsView()
            }
            .onAppear {
                viewModel.configure(with: settings)
                openRequestedChatIfNeeded()
                Task {
                    _ = await catalog.fetchOpenRouterModels()
                }
            }
            // Sidebar asked to open a recent chat.
            .onChange(of: openChat?.id) { _, _ in
                openRequestedChatIfNeeded()
            }
            // Sidebar asked for a brand-new chat.
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

    // MARK: - Message list

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(viewModel.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    if viewModel.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Thinking…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if let last = viewModel.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Chat home (empty state)

    /// Time-aware greeting for the chat home.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    /// Chat-first home: greeting, model picker pill, quick actions,
    /// and the same composer used once a conversation starts.
    private var homeView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PageMindDesign.rowSpacing) {
                Spacer(minLength: 24)

                // Brand mark above the greeting — the home screen's
                // designed anchor, matching the app icon.
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(PageMindDesign.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .shadow(color: PageMindDesign.brandIndigo.opacity(0.4), radius: 16, x: 0, y: 6)

                Text(greeting)
                    .font(.largeTitle.bold())
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Ask about a page, a PDF, a photo, or anything else.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                modelPickerPill

                // Suggestion chips: the same two quick actions as
                // before, restyled as chips instead of bordered buttons.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        suggestionChip("Attach a saved page", systemImage: "books.vertical") {
                            showAttachSheet = true
                        }
                        suggestionChip("Ask with web search", systemImage: "magnifyingglass") {
                            useWebSearch = true
                        }
                    }
                }

                if settings.apiKey(for: settings.selectedProvider) == nil
                    && settings.selectedProvider.requiresKey {
                    Button("Add an API key — or use OpenRouter free models") {
                        showSettingsSheet = true
                    }
                    .font(.footnote)
                }

                attachedPagesBar
                composer

                Spacer(minLength: 16)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    /// One suggestion chip on the chat home.
    private func suggestionChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(PageMindDesign.brandIndigo)
                Text(title)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(PageMindDesign.elevatedCard)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Current-model pill. Tap opens the model list; picking a model
    /// writes AppSettings.selectedModel, which reconfigures the chat.
    /// Elevated card with an indigo ring — a real control, not a grey
    /// blob.
    private var modelPickerPill: some View {
        Button { showModelPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(PageMindDesign.brandIndigo)
                Text(viewModel.selectedModel)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(PageMindDesign.elevatedCard)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(PageMindDesign.brandIndigo.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                }
                Section {
                    ForEach(filteredModels, id: \.self) { model in
                        modelRow(model)
                    }
                } header: {
                    Text(settings.selectedProvider.displayName)
                } footer: {
                    Text("Free models come from OpenRouter. The model you pick is used for the next reply. Vision means this provider accepts photo attachments — a text-only model still returns a provider error.")
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    Button("Refresh model list") {
                        Task { _ = await catalog.fetchOpenRouterModels() }
                    }
                }
            }
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            if model == "openrouter/free" || model.hasSuffix(":free") {
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

    // MARK: - Attached pages + composer

    private var attachedPagesBar: some View {
        Group {
            if !attachedPages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachedPages) { page in
                            HStack(spacing: 4) {
                                Text(page.title.isEmpty ? page.url : page.title)
                                    .lineLimit(1)
                                Button {
                                    attachedPages.removeAll { $0.id == page.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(PageMindDesign.elevatedCard)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)
            }
            if !attachedPDFNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(Array(attachedPDFNames.enumerated()), id: \.offset) { index, name in
                            HStack(spacing: 4) {
                                Text(name)
                                    .lineLimit(1)
                                Button {
                                    attachedPDFTexts.remove(at: index)
                                    attachedPDFNames.remove(at: index)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(PageMindDesign.elevatedCard)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)
            }
            if !attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(attachedImages) { image in
                            HStack(spacing: 4) {
                                Image(systemName: "photo")
                                Text(image.fileName)
                                    .lineLimit(1)
                                Button {
                                    attachedImages.removeAll { $0.id == image.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(PageMindDesign.elevatedCard)
                            .clipShape(Capsule())
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)
            }
            if !attachedImages.isEmpty && !viewModel.providerSupportsVision {
                Text("This provider does not support image input — the photo will be ignored. Switch to OpenAI, Anthropic, Gemini, or a vision model.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }
        }
    }

    /// The composer's "+" menu: everything that can be added to a message
    /// in one place, the way SurfMind organises it — photo, PDF file,
    /// a page from the Library, and the per-message web search / web
    /// fetch toggles. The toggles show a checkmark when on.
    private var composer: some View {
        VStack(spacing: 8) {
            HStack {
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
                    Toggle("Web fetch", isOn: $useWebFetch)
                } label: {
                    Image(systemName: "plus")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(PageMindDesign.brandGradient)
                        .clipShape(Circle())
                        .shadow(color: PageMindDesign.brandIndigo.opacity(0.35), radius: 8, x: 0, y: 3)
                }
                .accessibilityLabel("Add to message")

                if useWebSearch || useWebFetch {
                    HStack(spacing: 4) {
                        if useWebSearch {
                            Text("Web search")
                                .font(.caption2)
                                .bold()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(PageMindDesign.brandIndigo.opacity(0.15))
                                .foregroundStyle(PageMindDesign.brandIndigo)
                                .clipShape(Capsule())
                        }
                        if useWebFetch {
                            Text("Web fetch")
                                .font(.caption2)
                                .bold()
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(PageMindDesign.brandIndigo.opacity(0.15))
                                .foregroundStyle(PageMindDesign.brandIndigo)
                                .clipShape(Capsule())
                        }
                    }
                    .lineLimit(1)
                }

                Spacer()

                Text(viewModel.selectedModel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal)

            HStack(alignment: .bottom) {
                TextField("Ask PageMind anything…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                    .background(PageMindDesign.elevatedCard)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .disabled(viewModel.isStreaming)

                if viewModel.isStreaming {
                    Button("Stop") {
                        viewModel.cancelStreaming()
                    }
                    .frame(width: 36, height: 36)
                } else {
                    Button {
                        sendDraft()
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.body)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? AnyShapeStyle(Color.secondary.opacity(0.3))
                                    : AnyShapeStyle(PageMindDesign.brandGradient)
                            )
                            .clipShape(Circle())
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
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

// MARK: - Message row (Markdown-ish rendering)

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(message.role == "assistant" ? "PageMind" : "You")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(
                        message.role == "assistant"
                            ? PageMindDesign.brandIndigo
                            : .secondary
                    )
                Spacer()
                Button {
                    #if os(iOS)
                    UIPasteboard.general.string = message.content
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            // Markdown-ish: render real Markdown when it parses, fall back
            // to plain text. AttributedString(markdown:) is the only
            // dependency-free option on iOS 17.
            if let attributed = try? AttributedString(markdown: message.content) {
                Text(attributed)
                    .textSelection(.enabled)
            } else {
                Text(message.content)
                    .textSelection(.enabled)
            }

            if !message.citations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sources")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)
                    ForEach(message.citations) { citation in
                        Link(citation.title, destination: URL(string: citation.url) ?? URL(string: "https://example.com")!)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(12)
        .background(
            message.role == "assistant"
                ? PageMindDesign.elevatedCard
                : PageMindDesign.brandIndigo.opacity(0.16)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
