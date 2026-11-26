import XCTest
@testable import PageMind

/// Tests for ReaderExtractor's raw-HTML fallback (ReaderExtractor.swift).
/// The WKWebView JavaScript path cannot run in a unit test host, so these
/// cover the Swift fallback, the title extraction, and the excerpt helper.
final class ReaderExtractorTests: XCTestCase {

    func testStripsScriptStyleNavAndKeepsArticleText() {
        let html = """
        <html><head><title>Ignored Title</title><style>.x { color: red; }</style></head>
        <body>
        <nav>Home About Contact</nav>
        <script>var tracking = 1;</script>
        <article><h1>Real Article</h1><p>First paragraph of the article.</p><p>Second paragraph.</p></article>
        <footer>Copyright 2026</footer>
        </body></html>
        """
        let result = ReaderExtractor.extractReaderText(html: html)
        XCTAssertTrue(result.text.contains("Real Article"))
        XCTAssertTrue(result.text.contains("First paragraph of the article."))
        XCTAssertTrue(result.text.contains("Second paragraph."))
        XCTAssertFalse(result.text.contains("tracking"))
        XCTAssertFalse(result.text.contains("Home About Contact"))
        XCTAssertFalse(result.text.contains("Copyright 2026"))
        XCTAssertFalse(result.text.contains("color: red"))
    }

    func testPrefersOpenGraphTitleOverTitleTag() {
        let html = """
        <html><head>
        <meta property="og:title" content="OG Title Here">
        <title>Plain Title</title>
        </head><body><p>Body.</p></body></html>
        """
        let result = ReaderExtractor.extractReaderText(html: html)
        XCTAssertEqual(result.title, "OG Title Here")
    }

    func testFallsBackToTitleTagWhenNoOpenGraphTitle() {
        let html = "<html><head><title>Only Title</title></head><body><p>Body.</p></body></html>"
        let result = ReaderExtractor.extractReaderText(html: html)
        XCTAssertEqual(result.title, "Only Title")
    }

    func testDecodesHTMLEntities() {
        let html = "<html><body><p>Fish &amp; chips &mdash; it&rsquo;s &ldquo;great&rdquo; &#8212; really.</p></body></html>"
        let result = ReaderExtractor.extractReaderText(html: html)
        XCTAssertTrue(result.text.contains("Fish & chips"))
        XCTAssertTrue(result.text.contains("—"))
        XCTAssertTrue(result.text.contains("it’s"))
        XCTAssertTrue(result.text.contains("“great”"))
        XCTAssertFalse(result.text.contains("&amp;"))
    }

    func testEmptyHTMLReturnsEmpty() {
        let result = ReaderExtractor.extractReaderText(html: "")
        XCTAssertEqual(result.title, "")
        XCTAssertEqual(result.text, "")
    }

    func testExcerptShortTextIsUnchanged() {
        XCTAssertEqual(ReaderExtractor.excerpt("Short text.", maxChars: 100), "Short text.")
    }

    func testExcerptTruncatesAtWordBoundaryWithEllipsis() {
        let text = "One two three four five six seven eight nine ten."
        let excerpt = ReaderExtractor.excerpt(text, maxChars: 20)
        XCTAssertTrue(excerpt.hasSuffix("…"))
        XCTAssertFalse(excerpt.contains("seven"))
        // Cut at a word boundary, not mid-word.
        XCTAssertFalse(excerpt.contains("fiv…"))
    }

    func testExcerptCollapsesWhitespace() {
        let excerpt = ReaderExtractor.excerpt("One   two\n\nthree", maxChars: 100)
        XCTAssertEqual(excerpt, "One two three")
    }
}
