import Foundation

/// Fetches a YouTube video's captions and returns them as plain text,
/// so a video can be chatted about like a saved page.
///
/// No API key and no YouTube Data API: it uses YouTube's public
/// `timedtext` caption endpoints, the same ones the web player uses.
/// Best-effort by design — many videos have no captions, and some
/// (age-restricted, private, members-only) refuse the request. Every
/// failure returns `.failure(.noCaptions)` or `.failure(.network)` with
/// a user-facing reason; the caller shows that instead of crashing or
/// inventing a transcript.
enum YouTubeTranscriptFetcher {

    enum FetchError: LocalizedError {
        case notAYouTubeURL
        case noCaptions
        case network

        var errorDescription: String? {
            switch self {
            case .notAYouTubeURL:
                return "That is not a YouTube video URL."
            case .noCaptions:
                return "No captions are available for this video, so PageMind cannot read its transcript. Try a video with subtitles turned on."
            case .network:
                return "Could not reach YouTube. Check your connection and try again."
            }
        }
    }

    /// Extracts the 11-character video ID from watch / shorts / embed /
    /// live / youtu.be URLs. Returns nil for anything else.
    static func videoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let host = url.host?.lowercased() else { return nil }
        if host == "youtu.be" {
            let id = url.pathComponents.dropFirst().first ?? ""
            return isValidID(id) ? id : nil
        }
        guard host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") else {
            return nil
        }
        if let queryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value,
           isValidID(queryID) {
            return queryID
        }
        // /shorts/<id>, /embed/<id>, /live/<id>
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]),
           isValidID(parts[1]) {
            return parts[1]
        }
        return nil
    }

    /// Fetches the transcript for a video ID (or a full YouTube URL).
    /// Prefers English captions, falls back to the first available track.
    static func fetchTranscript(for urlString: String) async -> Result<String, FetchError> {
        guard let videoID = videoID(from: urlString) else {
            return .failure(.notAYouTubeURL)
        }
        // 1. List the caption tracks for this video.
        guard let listURL = URL(string: "https://www.youtube.com/api/timedtext?v=\(videoID)&type=list"),
              let listData = try? await get(url: listURL),
              let listXML = String(data: listData, encoding: .utf8),
              let trackLang = pickTrackLanguage(from: listXML) else {
            return .failure(.noCaptions)
        }
        // 2. Fetch the chosen track as JSON3 (events with text segments).
        let endpoints = [
            "https://www.youtube.com/api/timedtext?v=\(videoID)&lang=\(trackLang)&fmt=json3",
            "https://video.google.com/timedtext?lang=\(trackLang)&v=\(videoID)",
        ]
        for endpoint in endpoints {
            guard let url = URL(string: endpoint),
                  let data = try? await get(url: url) else { continue }
            if let text = parseJSON3(data), !text.isEmpty {
                return .success(text)
            }
            if let text = parseXMLTranscript(data), !text.isEmpty {
                return .success(text)
            }
        }
        return .failure(.noCaptions)
    }

    // MARK: - Private

    private static func isValidID(_ id: String) -> Bool {
        id.count == 11 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }

    private static func get(url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw FetchError.network
        }
        return data
    }

    /// Picks the caption track language from the track-list XML:
    /// English first, otherwise the first track listed.
    /// `<track id="0" name="" lang_code="en" .../>`
    static func pickTrackLanguage(from xml: String) -> String? {
        let pattern = #"lang_code="([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        var languages: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            languages.append(String(xml[range]))
        }
        if languages.contains("en") { return "en" }
        return languages.first
    }

    /// Parses the json3 caption format:
    /// `{"events":[{"segs":[{"utf8":"Hello "},{"utf8":"world"}]}]}`.
    /// Segments are joined, duplicate consecutive lines are dropped.
    static func parseJSON3(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = json["events"] as? [[String: Any]] else {
            return nil
        }
        var lines: [String] = []
        for event in events {
            guard let segs = event["segs"] as? [[String: Any]] else { continue }
            let line = segs.compactMap { $0["utf8"] as? String }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if lines.last != line {
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// Parses the XML caption format: `<transcript><text start="0">Hello</text>…`.
    static func parseXMLTranscript(_ data: Data) -> String? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"<text[^>]*>(.*?)</text>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        var lines: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let line = decodeXMLEntities(String(xml[range]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, lines.last != line else { continue }
            lines.append(line)
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    private static func decodeXMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
