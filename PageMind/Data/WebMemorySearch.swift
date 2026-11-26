import Foundation

/// Keyword search over saved pages (Web Memory) — v1.
///
/// This is plain keyword search: tokenise the query, score pages by
/// title matches (x3), tag matches (x2) and reader-text / excerpt
/// matches (x1), with recency as a tiebreak. Semantic search and
/// on-device embeddings are a Pro v1.1 item, not here.
struct WebMemorySearch {

    /// Search saved pages and return them ranked best-first.
    /// Pages with no matching token are excluded. An empty query
    /// returns all pages, newest first.
    func search(query: String, in pages: [SavedPage]) -> [SavedPage] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else {
            return pages.sorted { $0.savedAt > $1.savedAt }
        }

        let scored: [(page: SavedPage, score: Int)] = pages.compactMap { page in
            let score = score(page: page, tokens: tokens)
            return score > 0 ? (page, score) : nil
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.page.savedAt > rhs.page.savedAt
            }
            .map(\.page)
    }

    /// Prefix suggestions drawn from page titles and tags.
    /// Returns up to 8 unique suggestions, titles first, then tags.
    func suggestions(for prefix: String, in pages: [SavedPage]) -> [String] {
        let needle = prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        var results: [String] = []

        for page in pages {
            if page.title.lowercased().contains(needle), !seen.contains(page.title) {
                seen.insert(page.title)
                results.append(page.title)
            }
            for tag in page.tags where tag.lowercased().hasPrefix(needle) && !seen.contains(tag) {
                seen.insert(tag)
                results.append(tag)
            }
            if results.count >= 8 { break }
        }
        return Array(results.prefix(8))
    }

    // MARK: - Private

    private func tokenize(_ query: String) -> [String] {
        query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
    }

    private func score(page: SavedPage, tokens: [String]) -> Int {
        let title = page.title.lowercased()
        let tags = page.tags.map { $0.lowercased() }
        // readerText / excerpt are non-optional Strings on SavedPage.
        let body = (page.readerText.isEmpty ? page.excerpt : page.readerText).lowercased()
        var total = 0
        for token in tokens {
            if title.contains(token) { total += 3 }
            if tags.contains(where: { $0.contains(token) }) { total += 2 }
            if body.contains(token) { total += 1 }
        }
        return total
    }
}
