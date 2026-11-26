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

    @StateObject private var viewModel = ChatViewModel()
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
    @State private var isSearchingWeb = false
    @State private var showSettingsSheet = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList

                if let error = viewModel.errorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                        if let hint = viewModel.errorHint {
                            Text(hint)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
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

                if isSearchingWeb {
                    HStack {
                        ProgressView()
                        Text("Searching the web…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                attachedPagesBar
                composer
            }
            .navigationTitle(viewModel.currentChat?.title ?? "Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        viewModel.newChat()
                        attachedPages = []
                        attachedPDFTexts = []
                        attachedPDFNames = []
                        attachedImages = []
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(availableModels, id: \.self) { model in
                            Button {
                                viewModel.selectedModel = model
                            } label: {
                                if model == viewModel.selectedModel {
                                    Label(model, systemImage: "checkmark")
                                } else {
                                    Text(model)
                                }
                            }
                        }
                    } label: {
                        Label(viewModel.selectedModel, systemImage: "chevron.down")
                            .font(.footnote)
                    }
                }
            }
            .sheet(isPresented: $showAttachSheet) {
                attachPageSheet
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
                Task {
                    _ = await catalog.fetchOpenRouterModels()
                }
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
                    if viewModel.messages.isEmpty {
                        emptyState
                    }
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

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask about a page, a PDF, a photo, or anything else.")
                .font(.headline)
            Text("Attach a saved page, turn on web search, or ask from the Browser tab and PageMind will use that page as context.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Attach a saved page") { showAttachSheet = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Ask with web search") { useWebSearch = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if settings.apiKey(for: settings.selectedProvider) == nil
                && settings.selectedProvider.requiresKey {
                Button("Add an API key — or use OpenRouter free models") {
                    showSettingsSheet = true
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 24)
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
                            .background(Color.secondary.opacity(0.15))
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
                            .background(Color.secondary.opacity(0.15))
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
                            .background(Color.secondary.opacity(0.15))
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

    private var composer: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Ask with web search", isOn: $useWebSearch)
                    .font(.footnote)
                    .toggleStyle(.switch)
                Spacer()
                Button {
                    showAttachSheet = true
                } label: {
                    Label("Attach page", systemImage: "paperclip")
                        .font(.footnote)
                }
                Button {
                    showPDFImporter = true
                } label: {
                    Label("PDF", systemImage: "doc.fill")
                        .font(.footnote)
                }
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Photo", systemImage: "photo")
                        .font(.footnote)
                }
                .disabled(attachedImages.count >= VisionImagePrep.maxImagesPerChat)
            }
            .padding(.horizontal)

            HStack(alignment: .bottom) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(viewModel.isStreaming)

                if viewModel.isStreaming {
                    Button("Stop") {
                        viewModel.cancelStreaming()
                    }
                } else {
                    Button {
                        sendDraft()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
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

        if useWebSearch {
            isSearchingWeb = true
            Task {
                let results = await WebSearchService().search(
                    query: prompt,
                    braveAPIKey: settings.braveAPIKey
                )
                isSearchingWeb = false
                viewModel.send(
                    prompt: prompt,
                    contextPages: attachedPages,
                    attachments: attachedPDFTexts,
                    webSearchResults: results,
                    imageAttachments: attachedImages
                )
            }
        } else {
            viewModel.send(
                prompt: prompt,
                contextPages: attachedPages,
                attachments: attachedPDFTexts,
                imageAttachments: attachedImages
            )
        }
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
                    .foregroundStyle(.secondary)
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
                ? Color.secondary.opacity(0.12)
                : Color.accentColor.opacity(0.12)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
