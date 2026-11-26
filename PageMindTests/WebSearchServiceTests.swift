import XCTest
@testable import PageMind

/// Tests for WebSearchService.parseDuckDuckGoHTML (Search/WebSearch.swift).
/// Only the pure HTML parser is tested — no network calls are made.
final class WebSearchServiceTests: XCTestCase {

    private let sampleHTML = """
    <html><body>
    <div class="results">
    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Ffirst&amp;rut=abc">First Result</a>
    <a class="result__a" href="https://example.com/direct">Direct Result</a>
    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fthird">Third <b>Result</b></a>
    <a class="result__a" href="">Empty Href</a>
    <a class="other" href="https://example.com/not-a-result">Not A Result</a>
    </div>
    </body></html>
    """

    func testParsesRedirectAndDirectLinks() {
        let results = WebSearchService.parseDuckDuckGoHTML(sampleHTML)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].title, "First Result")
        XCTAssertEqual(results[0].url, "https://example.com/first")
        XCTAssertEqual(results[1].title, "Direct Result")
        XCTAssertEqual(results[1].url, "https://example.com/direct")
    }

    func testStripsTagsFromTitles() {
        let results = WebSearchService.parseDuckDuckGoHTML(sampleHTML)
        XCTAssertEqual(results[2].title, "Third Result")
        XCTAssertEqual(results[2].url, "https://example.com/third")
    }

    func testEmptyHTMLReturnsEmpty() {
        XCTAssertTrue(WebSearchService.parseDuckDuckGoHTML("").isEmpty)
        XCTAssertTrue(WebSearchService.parseDuckDuckGoHTML("<html><body>No results here.</body></html>").isEmpty)
    }

    func testCapsAtEightResults() {
        var html = "<html><body>"
        for index in 0..<20 {
            html += "<a class=\"result__a\" href=\"https://example.com/\(index)\">Result \(index)</a>"
        }
        html += "</body></html>"
        let results = WebSearchService.parseDuckDuckGoHTML(html)
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(results.first?.title, "Result 0")
        XCTAssertEqual(results.last?.title, "Result 7")
    }
}
