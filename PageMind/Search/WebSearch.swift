import Foundation

/// Free web search for grounding chat answers.
/// - With a Brave Search API key: Brave Web Search API.
/// - Without one: DuckDuckGo's HTML endpoint (no key needed).
/// Never throws and never crashes: any failure returns [].
struct WebSearchService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, braveAPIKey: String?) async -> [SourceCitation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if let key = braveAPIKey, !key.isEmpty {
            let results = await searchBrave(query: trimmed, apiKey: key)
            if !results.isEmpty {
                return results
            }
            // Fall through to DuckDuckGo rather than returning nothing
            // when the Brave call fails.
        }
        return await searchDuckDuckGo(query: trimmed)
    }

    // MARK: - Brave

    private func searchBrave(query: String, apiKey: String) async -> [SourceCitation] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.search.brave.com/res/v1/web/search?q=\(encoded)&count=8") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let web = json["web"] as? [String: Any],
                  let results = web["results"] as? [[String: Any]] else {
                return []
            }
            return results.compactMap { item in
                guard let title = item["title"] as? String,
                      let url = item["url"] as? String,
                      !title.isEmpty, !url.isEmpty else { return nil }
                return SourceCitation(title: title, url: url)
            }
            .prefix(8)
            .map { $0 }
        } catch {
            return []
        }
    }

    // MARK: - DuckDuckGo (no key)

    private func searchDuckDuckGo(query: String) async -> [SourceCitation] {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return []
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // A browser User-Agent: the html endpoint serves a minimal page
        // to non-browser agents.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let html = String(data: data, encoding: .utf8) else {
                return []
            }
            return Self.parseDuckDuckGoHTML(html)
        } catch {
            return []
        }
    }

    /// Parses `result__a` links from DuckDuckGo's HTML results page.
    /// DuckDuckGo wraps result URLs as `/l/?uddg=<percent-encoded url>`.
    static func parseDuckDuckGoHTML(_ html: String) -> [SourceCitation] {
        var citations: [SourceCitation] = []
        // <a ... class="result__a" href="...">Title</a>
        let pattern = #"<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matches {
            guard match.numberOfRanges > 2,
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }
            let href = String(html[hrefRange])
            let rawTitle = String(html[titleRange])
            let title = rawTitle
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = Self.unwrapDuckDuckGoURL(href),
                  !title.isEmpty else { continue }
            citations.append(SourceCitation(title: title, url: url))
            if citations.count >= 8 { break }
        }
        return citations
    }

    private static func unwrapDuckDuckGoURL(_ href: String) -> String? {
        // Direct result URL.
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            return href
        }
        // Redirect form: //duckduckgo.com/l/?uddg=<encoded>&... or /l/?uddg=...
        guard let uddgRange = href.range(of: "uddg=") else { return nil }
        var encoded = String(href[uddgRange.upperBound...])
        if let ampIndex = encoded.firstIndex(of: "&") {
            encoded = String(encoded[..<ampIndex])
        }
        return encoded.removingPercentEncoding
    }
}
