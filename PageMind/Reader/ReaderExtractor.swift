import Foundation

/// On-device Readability-style article extraction. Dependency-free.
/// Two paths: JavaScript run inside WKWebView (preferred — it sees the
/// live DOM), and a plain-HTML fallback for when JS is unavailable.
enum ReaderExtractor {

    // MARK: - (a) JavaScript for WKWebView

    /// Evaluates to `{ "title": String, "text": String }`.
    /// Removes script/style/nav/header/footer/aside and other chrome,
    /// then picks the element containing the most <p> text.
    static let javascript = """
    (() => {
      const clone = document.cloneNode(true);
      const remove = (sel) => clone.querySelectorAll(sel).forEach((el) => el.remove());
      remove('script, style, noscript, iframe, svg, canvas, video, audio, form, button, input, select, textarea');
      remove('nav, header, footer, aside, [role="navigation"], [role="banner"], [role="contentinfo"], [aria-hidden="true"]');
      remove('.ad, .ads, .advertisement, .cookie-banner, .paywall, .newsletter, .share-buttons, .comments');
      const candidates = clone.querySelectorAll('article, main, [role="main"], div, section');
      let best = null;
      let bestScore = 0;
      candidates.forEach((el) => {
        const paragraphs = el.querySelectorAll('p');
        let text = '';
        paragraphs.forEach((p) => { text += p.innerText + '\\n'; });
        const score = text.trim().length;
        if (score > bestScore) { bestScore = score; best = el; }
      });
      const target = best || clone.body || clone.documentElement;
      const title = (document.querySelector('meta[property="og:title"]')?.content)
        || document.title
        || '';
      let text = '';
      target.querySelectorAll('h1, h2, h3, p, li, blockquote').forEach((el) => {
        const t = el.innerText.trim();
        if (t.length > 0) { text += t + '\\n\\n'; }
      });
      if (!text.trim()) { text = (target.innerText || '').trim(); }
      return { title: title.trim(), text: text.replace(/\\n{3,}/g, '\\n\\n').trim() };
    })()
    """

    // MARK: - (b) Swift fallback for raw HTML

    /// Best-effort extraction from raw HTML when JavaScript is unavailable.
    /// Strips script/style/nav/header/footer/aside blocks, removes remaining
    /// tags, decodes common entities, and collapses whitespace.
    static func extractReaderText(html: String) -> (title: String, text: String) {
        let title = extractTitle(from: html)

        var working = html

        // Drop whole blocks that are page chrome, not article text.
        // (?s) lets . match newlines so multi-line blocks are removed whole.
        let blockPatterns = [
            #"(?s)<script[^>]*>.*?</script>"#,
            #"(?s)<style[^>]*>.*?</style>"#,
            #"(?s)<noscript[^>]*>.*?</noscript>"#,
            #"(?s)<nav[^>]*>.*?</nav>"#,
            #"(?s)<header[^>]*>.*?</header>"#,
            #"(?s)<footer[^>]*>.*?</footer>"#,
            #"(?s)<aside[^>]*>.*?</aside>"#,
            #"(?s)<!--.*?-->"#,
        ]
        for pattern in blockPatterns {
            working = working.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // Keep paragraph-like boundaries, then strip every remaining tag.
        working = working.replacingOccurrences(
            of: #"</(p|h[1-6]|li|blockquote|div|section|article|br)[^>]*>"#,
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        working = working.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )

        var text = decodeHTMLEntities(in: working)
        // Collapse runs of blank lines and repeated spaces.
        text = text.replacingOccurrences(
            of: #"[ \t]+"#,
            with: " ",
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: #"\n[ \t]*\n+"#,
            with: "\n\n",
            options: .regularExpression
        )
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title: title, text: text)
    }

    private static func extractTitle(from html: String) -> String {
        // Prefer og:title, fall back to <title>.
        let patterns = [
            #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']"#,
            #"<title[^>]*>(.*?)</title>"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(
                    in: html,
                    range: NSRange(html.startIndex..., in: html)
                  ),
                  match.numberOfRanges > 1,
                  let groupRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            let title = decodeHTMLEntities(in: String(html[groupRange]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }
        return ""
    }

    private static func decodeHTMLEntities(in string: String) -> String {
        var result = string
        let entities: [String: String] = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&apos;": "'",
            "&#39;": "'",
            "&nbsp;": " ",
            "&mdash;": "—",
            "&ndash;": "–",
            "&rsquo;": "’",
            "&lsquo;": "‘",
            "&rdquo;": "”",
            "&ldquo;": "“",
            "&hellip;": "…",
            "&copy;": "©",
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Numeric character references: &#123; and &#x7B;
        result = replaceNumericEntities(in: result)
        return result
    }

    private static func replaceNumericEntities(in string: String) -> String {
        var result = string
        let pattern = #"&#(x[0-9a-fA-F]+|\d+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let groupRange = Range(match.range(at: 1), in: result) else { continue }
            let code = String(result[groupRange])
            let value: UInt32?
            if code.hasPrefix("x") || code.hasPrefix("X") {
                value = UInt32(code.dropFirst(), radix: 16)
            } else {
                value = UInt32(code)
            }
            if let value, let scalar = Unicode.Scalar(value) {
                result.replaceSubrange(fullRange, with: String(scalar))
            }
        }
        return result
    }

    // MARK: - (c) Excerpt

    /// First `maxChars` characters, cut at a word boundary where possible,
    /// with an ellipsis when truncated.
    static func excerpt(_ text: String, maxChars: Int) -> String {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard cleaned.count > maxChars else { return cleaned }
        let prefix = String(cleaned.prefix(maxChars))
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return prefix + "…"
    }
}
