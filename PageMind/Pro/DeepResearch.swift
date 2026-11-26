import Foundation

/// Deep Research engine: multi-source research with citations.
///
/// Flow: (1) run web searches for the topic and two variants,
/// (2) fetch the top pages and extract Reader text on-device,
/// (3) ask the user's provider to synthesise a structured report from
/// those sources only, (4) return the report as Markdown with a source
/// list. The report is saved by the caller as a SavedPage note.
///
/// Progress is reported through the `onProgress` closure so the UI can
/// show which stage it is in. Nothing here is faked: if search returns
/// nothing or no page can be fetched, the run fails with an error.
@MainActor
final class DeepResearchEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var progressText = ""

    private var runTask: Task<DeepResearchReport, Error>?

    struct DeepResearchReport {
        var topic: String
        var markdown: String
        var sources: [SourceCitation]
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        progressText = "Cancelled."
    }

    /// Runs a full research pass. Throws on failure (no search results,
    /// no fetchable sources, provider error, or cancellation).
    func research(
        topic: String,
        sourceCount: Int,
        settings: AppSettings,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> DeepResearchReport {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ResearchError.emptyTopic
        }
        guard !isRunning else { throw ResearchError.alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        func report(_ text: String) {
            progressText = text
            onProgress?(text)
        }

        let task = Task<DeepResearchReport, Error> {
            // 1. Search: the topic plus two variants, for breadth.
            report("Searching the web…")
            let search = WebSearchService()
            var citations: [SourceCitation] = []
            var seenURLs = Set<String>()
            let queries = [trimmed, "\(trimmed) overview", "\(trimmed) latest"]
            for query in queries {
                try Task.checkCancellation()
                let results = await search.search(query: query, braveAPIKey: settings.braveAPIKey)
                for result in results where !seenURLs.contains(result.url) {
                    seenURLs.insert(result.url)
                    citations.append(result)
                }
                if citations.count >= sourceCount { break }
            }
            citations = Array(citations.prefix(sourceCount))
            guard !citations.isEmpty else {
                throw ResearchError.noSearchResults
            }

            // 2. Fetch + extract each source (cap: 5 pages, 3,000 chars each).
            report("Reading \(citations.count) source(s)…")
            var sourceTexts: [(citation: SourceCitation, text: String)] = []
            for citation in citations.prefix(5) {
                try Task.checkCancellation()
                if let text = await Self.fetchPageText(urlString: citation.url), !text.isEmpty {
                    sourceTexts.append((citation, String(text.prefix(3_000))))
                }
            }
            guard !sourceTexts.isEmpty else {
                throw ResearchError.noReadableSources
            }

            // 3. Synthesise from the fetched sources only.
            report("Writing the report…")
            let sourcesBlock = sourceTexts.enumerated().map { index, item in
                "[\(index + 1)] \(item.citation.title) (\(item.citation.url))\n\(item.text)"
            }.joined(separator: "\n\n---\n\n")
            let reportMarkdown = try await ChatCompletion.ask(
                settings: settings,
                prompt: """
                Research topic: \(trimmed)

                Sources (use only these — do not invent facts or sources):
                \(sourcesBlock)

                Write a research report in Markdown with exactly these sections:
                ## Summary
                A short paragraph with the answer in plain language.
                ## Key points
                Bullet points, each ending with the source number it came from, like [1].
                ## Different viewpoints
                Where the sources disagree or cover different angles, say so. If they agree, say that.
                ## Open questions
                What the sources do not answer.
                Keep it factual and cite with [n] numbers matching the source list above.
                """,
                systemPrompt: "You write careful research reports. Only use the sources provided. If a source does not support a claim, do not make it."
            )
            return DeepResearchReport(
                topic: trimmed,
                markdown: reportMarkdown,
                sources: citations
            )
        }
        runTask = task
        return try await task.value
    }

    // MARK: - Fetching

    /// Fetches a URL and extracts Reader text. Returns nil on any failure
    /// (network error, non-HTML, unreadable page) — the caller skips it.
    private static func fetchPageText(urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return nil
            }
            let extracted = ReaderExtractor.extractReaderText(html: html)
            let text = extracted.text.isEmpty ? extracted.title : extracted.text
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    enum ResearchError: LocalizedError {
        case emptyTopic
        case alreadyRunning
        case noSearchResults
        case noReadableSources

        var errorDescription: String? {
            switch self {
            case .emptyTopic:
                return "Enter a research topic first."
            case .alreadyRunning:
                return "A research run is already in progress."
            case .noSearchResults:
                return "Web search returned no results for this topic. Try different words."
            case .noReadableSources:
                return "Search found pages, but none could be read. Try a different topic."
            }
        }
    }
}
