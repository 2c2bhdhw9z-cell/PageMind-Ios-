import XCTest
@testable import PageMind

/// Tests for WebMemorySearch (Data/WebMemorySearch.swift), the keyword
/// search behind the Library / Web Memory. SavedPage is a SwiftData
/// @Model, but instances can be created without a container — these
/// tests never persist anything.
final class WebMemorySearchTests: XCTestCase {

    private func page(title: String, text: String, tags: [String] = [], daysAgo: Double = 0) -> SavedPage {
        SavedPage(
            url: "https://example.com/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
            title: title,
            readerText: text,
            excerpt: String(text.prefix(100)),
            savedAt: Date().addingTimeInterval(-daysAgo * 86_400),
            tags: tags
        )
    }

    private var pages: [SavedPage] {
        [
            page(title: "Visa Guide", text: "How to renew a tourist visa in Japan.", tags: ["travel"], daysAgo: 10),
            page(title: "Swift Concurrency", text: "Actors, tasks and structured concurrency in Swift.", tags: ["code"], daysAgo: 1),
            page(title: "Japan Travel Tips", text: "Trains, food and visas for a trip to Japan.", tags: ["travel"], daysAgo: 2),
        ]
    }

    func testEmptyQueryReturnsAllNewestFirst() {
        let results = WebMemorySearch().search(query: "", in: pages)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.first?.title, "Swift Concurrency")
        XCTAssertEqual(results.last?.title, "Visa Guide")
    }

    func testTitleMatchRanksAboveBodyMatch() {
        // "visa" is in the title of Visa Guide and only in the body of
        // Japan Travel Tips — the title match must come first.
        let results = WebMemorySearch().search(query: "visa", in: pages)
        XCTAssertEqual(results.map(\.title), ["Visa Guide", "Japan Travel Tips"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(WebMemorySearch().search(query: "quantum", in: pages).isEmpty)
    }

    func testSearchIsCaseInsensitive() {
        let results = WebMemorySearch().search(query: "SWIFT", in: pages)
        XCTAssertEqual(results.map(\.title), ["Swift Concurrency"])
    }

    func testTagMatchCounts() {
        let results = WebMemorySearch().search(query: "travel", in: pages)
        XCTAssertEqual(Set(results.map(\.title)), ["Visa Guide", "Japan Travel Tips"])
    }

    func testSingleCharacterTokensAreIgnored() {
        // "a" alone tokenises to nothing, so it behaves like an empty query.
        let results = WebMemorySearch().search(query: "a", in: pages)
        XCTAssertEqual(results.count, 3)
    }

    func testSuggestionsFromTitlesAndTags() {
        let suggestions = WebMemorySearch().suggestions(for: "jap", in: pages)
        XCTAssertTrue(suggestions.contains("Japan Travel Tips"))
        let tagSuggestions = WebMemorySearch().suggestions(for: "trav", in: pages)
        XCTAssertTrue(tagSuggestions.contains("travel"))
    }

    func testSuggestionsEmptyForBlankPrefix() {
        XCTAssertTrue(WebMemorySearch().suggestions(for: "", in: pages).isEmpty)
        XCTAssertTrue(WebMemorySearch().suggestions(for: "zzz", in: pages).isEmpty)
    }
}
