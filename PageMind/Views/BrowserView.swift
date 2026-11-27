import SwiftUI
import WebKit
import SwiftData

struct BrowserView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var pageContext: PageContextStore

    @State private var addressText = ""
    /// nil = PageMind's own start page. (It used to open on example.com,
    /// and DuckDuckGo's home page shows an ad for its own browser.)
    @State private var currentURL: URL?
    @State private var progress: Double = 0
    @State private var isLoading = false
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isReaderMode = false
    @State private var readerTitle = ""
    @State private var readerText = ""
    @State private var showReaderSheet = false
    @State private var statusMessage: String?
    @State private var navigateRequestID = UUID()
    @State private var showAgentSheet = false
    @State private var showPaywallSheet = false
    @State private var isFetchingTranscript = false

    @StateObject private var webViewHolder = WebViewHolder()
    @StateObject private var agent = BrowserAgent()
    @StateObject private var store = StoreManager.shared

    @Query(sort: \SavedPage.savedAt, order: .reverse) private var savedPages: [SavedPage]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScreenHeader(title: "Browser")
                addressBar

                if progress > 0 && progress < 1 {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(PageMindDesign.brandIndigo)
                }

                if currentURL == nil {
                    startPage
                } else {
                    WebViewContainer(
                        holder: webViewHolder,
                        url: currentURL,
                        navigateRequestID: navigateRequestID,
                        onWebViewCreated: { webView in
                            agent.webView = webView
                        },
                        onProgress: { progress = $0 },
                        onLoadingChange: { isLoading = $0 },
                        onNavigationChange: { back, forward, url in
                            canGoBack = back
                            canGoForward = forward
                            if let url {
                                addressText = url.absoluteString
                            }
                        }
                    )

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }

                    actionBar
                }
            }
            .background(PageMindDesign.appBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showReaderSheet) {
                readerSheet
            }
            .sheet(isPresented: $showAgentSheet) {
                NavigationStack {
                    BrowserAgentView()
                        .environmentObject(agent)
                }
            }
            .sheet(isPresented: $showPaywallSheet) {
                PaywallView()
            }
        }
    }

    // MARK: - Start page

    /// Shown before any page is open: what the Browser does, a few
    /// places to start, and the most recent saved pages.
    private var startPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(spacing: 10) {
                    BrandMark(size: 52)
                    Text("Browse with PageMind")
                        .font(.title2.weight(.semibold))
                    Text("Open any page, then tap Ask to chat about it, Reader for a clean view, or Save page to keep it in your Library.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Start somewhere")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        startLink("Wikipedia", systemImage: "book", url: "https://en.m.wikipedia.org")
                        startLink("YouTube", systemImage: "play.rectangle", url: "https://m.youtube.com")
                        startLink("BBC News", systemImage: "newspaper", url: "https://www.bbc.com/news")
                        startLink("Reddit", systemImage: "bubble.left.and.bubble.right", url: "https://www.reddit.com")
                    }
                }

                if !savedPages.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recently saved")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(savedPages.prefix(4))) { page in
                                Button {
                                    openAddress(page.url)
                                } label: {
                                    HStack(spacing: 12) {
                                        IconChip(systemImage: "globe")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(page.title.isEmpty ? page.url : page.title)
                                                .font(.subheadline)
                                                .foregroundStyle(PageMindDesign.primaryText)
                                                .lineLimit(1)
                                            Text(URL(string: page.url)?.host ?? page.url)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(PageMindDesign.elevatedCard)
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startLink(_ title: String, systemImage: String, url: String) -> some View {
        Button {
            openAddress(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(PageMindDesign.brandIndigo)
                Text(title)
            }
            .font(.subheadline)
            .foregroundStyle(PageMindDesign.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(PageMindDesign.elevatedCard))
        }
        .buttonStyle(.plain)
    }

    private func openAddress(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        addressText = urlString
        currentURL = url
        navigateRequestID = UUID()
    }

    // MARK: - Bars

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button {
                webViewHolder.webView?.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canGoBack ? PageMindDesign.primaryText : .secondary)
                    .frame(width: 34, height: 34)
                    .background(PageMindDesign.elevatedCard)
                    .clipShape(Circle())
            }
            .disabled(!canGoBack)

            Button {
                webViewHolder.webView?.goForward()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canGoForward ? PageMindDesign.primaryText : .secondary)
                    .frame(width: 34, height: 34)
                    .background(PageMindDesign.elevatedCard)
                    .clipShape(Circle())
            }
            .disabled(!canGoForward)

            TextField("Search or enter website", text: $addressText, onCommit: go)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(PageMindDesign.elevatedCard)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)

            Button("Go") { go() }
                .font(.subheadline)
                .bold()
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(PageMindDesign.brandGradient)
                .clipShape(Capsule())
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var actionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                actionChip("Reader", systemImage: isReaderMode ? "doc.text.fill" : "doc.text") {
                    isReaderMode.toggle()
                    if isReaderMode {
                        extractReaderText { showReaderSheet = true }
                    }
                }

                actionChip("Save page", systemImage: "bookmark") {
                    saveCurrentPage()
                }

                actionChip("Ask", systemImage: "message") {
                    askAboutCurrentPage()
                }
                .disabled(isLoading)

                if isYouTubePage {
                    actionChip("Transcript", systemImage: "captions.bubble") {
                        fetchYouTubeTranscript()
                    }
                    .disabled(isLoading || isFetchingTranscript)
                }

                // The Agent is the Pro hero action: gradient chip, white text.
                Button {
                    if store.isPro {
                        showAgentSheet = true
                    } else {
                        showPaywallSheet = true
                    }
                } label: {
                    Label("Agent", systemImage: "wand.and.stars")
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(PageMindDesign.brandGradient)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
        }
        .font(.footnote)
        .padding(.vertical, 8)
    }

    /// One action-bar chip: icon + label on the elevated card surface.
    private func actionChip(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(PageMindDesign.elevatedCard)
                .foregroundStyle(PageMindDesign.primaryText)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Whether the current page is a YouTube video (transcript button).
    private var isYouTubePage: Bool {
        guard let url = webViewHolder.webView?.url ?? currentURL,
              let host = url.host?.lowercased() else { return false }
        return host == "youtu.be" || host.hasSuffix("youtube.com")
    }

    private var readerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(readerTitle)
                        .font(.title2)
                        .bold()
                    Text(readerText)
                }
                .padding()
            }
            .navigationTitle("Reader Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        isReaderMode = false
                        showReaderSheet = false
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func go() {
        let input = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let urlString: String
        if input.contains("://") {
            urlString = input
        } else if input.contains(".") && !input.contains(" ") {
            urlString = "https://" + input
        } else {
            // Plain words: run a web search instead of guessing a host.
            let query = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            urlString = "https://duckduckgo.com/?q=\(query)"
        }
        guard let url = URL(string: urlString) else { return }
        currentURL = url
        navigateRequestID = UUID()
    }

    /// Runs the Readability-style JS in the page and returns title + text.
    private func extractReaderText(completion: @escaping () -> Void) {
        guard let webView = webViewHolder.webView else { return }
        webView.evaluateJavaScript(ReaderExtractor.javascript) { result, _ in
            if let dict = result as? [String: Any] {
                readerTitle = dict["title"] as? String ?? webView.title ?? ""
                readerText = dict["text"] as? String ?? ""
            } else if let text = result as? String {
                readerText = text
            }
            completion()
        }
    }

    /// Fetches the YouTube transcript for the open video (public caption
    /// endpoints, no API key) and saves it as a Library page so it can be
    /// chatted about like any saved page. Fails gracefully when the video
    /// has no captions.
    private func fetchYouTubeTranscript() {
        guard let url = webViewHolder.webView?.url ?? currentURL else { return }
        isFetchingTranscript = true
        statusMessage = "Fetching transcript…"
        Task {
            let result = await YouTubeTranscriptFetcher.fetchTranscript(for: url.absoluteString)
            isFetchingTranscript = false
            switch result {
            case .success(let transcript):
                let page = SavedPage(
                    url: url.absoluteString,
                    title: webViewHolder.webView?.title ?? url.absoluteString,
                    readerText: transcript,
                    excerpt: ReaderExtractor.excerpt(transcript, maxChars: 300)
                )
                modelContext.insert(page)
                do {
                    try modelContext.save()
                    refreshWidgetSnapshot()
                    statusMessage = "Transcript saved to your Library — ask about it in Chat."
                } catch {
                    statusMessage = "Could not save the transcript: \(error.localizedDescription)"
                }
            case .failure(let error):
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Refreshes the widget snapshot after the Library changes.
    private func refreshWidgetSnapshot() {
        let pages = (try? modelContext.fetch(FetchDescriptor<SavedPage>())) ?? []
        WidgetDataWriter.writeSnapshot(pages: pages)
    }

    private func saveCurrentPage() {
        guard let url = webViewHolder.webView?.url ?? currentURL else { return }
        extractReaderText {
            let page = SavedPage(
                url: url.absoluteString,
                title: readerTitle.isEmpty ? (webViewHolder.webView?.title ?? url.host ?? url.absoluteString) : readerTitle,
                readerText: readerText,
                excerpt: ReaderExtractor.excerpt(readerText, maxChars: 300)
            )
            modelContext.insert(page)
            do {
                try modelContext.save()
                refreshWidgetSnapshot()
                statusMessage = "Saved “\(page.title)” to your Library."
            } catch {
                statusMessage = "Could not save this page: \(error.localizedDescription)"
            }
        }
    }

    private func askAboutCurrentPage() {
        guard let url = webViewHolder.webView?.url ?? currentURL else { return }
        extractReaderText {
            let page = SavedPage(
                url: url.absoluteString,
                title: readerTitle.isEmpty ? (webViewHolder.webView?.title ?? url.host ?? url.absoluteString) : readerTitle,
                readerText: readerText,
                excerpt: ReaderExtractor.excerpt(readerText, maxChars: 300)
            )
            modelContext.insert(page)
            try? modelContext.save()
            refreshWidgetSnapshot()
            statusMessage = "Opening Chat with this page as context."
            pageContext.askAbout(page: page)
        }
    }
}

// MARK: - WKWebView wrapper

/// Holds the single WKWebView instance so SwiftUI state updates do not
/// recreate it (which would lose navigation history and scroll position).
final class WebViewHolder: ObservableObject {
    var webView: WKWebView?
}

private struct WebViewContainer: UIViewRepresentable {
    let holder: WebViewHolder
    let url: URL?
    let navigateRequestID: UUID
    let onWebViewCreated: (WKWebView) -> Void
    let onProgress: (Double) -> Void
    let onLoadingChange: (Bool) -> Void
    let onNavigationChange: (Bool, Bool, URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onProgress: onProgress,
            onLoadingChange: onLoadingChange,
            onNavigationChange: onNavigationChange
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // STUB: No content blockers, desktop-mode toggle, or extensions —
        // Free only opens and navigates. Those belong to a later build.
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.progressObservation = webView.observe(
            \.estimatedProgress,
            options: [.new]
        ) { _, change in
            if let value = change.newValue {
                onProgress(value)
            }
        }
        holder.webView = webView
        onWebViewCreated(webView)
        if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only navigate when the request id changes (address-bar "Go"),
        // never on every SwiftUI state update.
        if context.coordinator.lastNavigateRequestID != navigateRequestID {
            context.coordinator.lastNavigateRequestID = navigateRequestID
            if let url, webView.url != url {
                webView.load(URLRequest(url: url))
            }
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onProgress: (Double) -> Void
        let onLoadingChange: (Bool) -> Void
        let onNavigationChange: (Bool, Bool, URL?) -> Void
        var progressObservation: NSKeyValueObservation?
        var lastNavigateRequestID: UUID?

        init(
            onProgress: @escaping (Double) -> Void,
            onLoadingChange: @escaping (Bool) -> Void,
            onNavigationChange: @escaping (Bool, Bool, URL?) -> Void
        ) {
            self.onProgress = onProgress
            self.onLoadingChange = onLoadingChange
            self.onNavigationChange = onNavigationChange
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            onLoadingChange(true)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onLoadingChange(false)
            onProgress(1)
            onNavigationChange(webView.canGoBack, webView.canGoForward, webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onLoadingChange(false)
        }
    }
}
