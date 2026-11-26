import XCTest
import SwiftData
@testable import PageMind

/// Tests for PendingPageImporter (Data/PendingPageImporter.swift).
///
/// The pure dedupe helpers are tested directly. The full
/// `importPendingPages(modelContext:)` round trip is tested only when a
/// UserDefaults App Group suite is actually available on the test host —
/// without the App Group entitlement it returns nil, and the test is
/// skipped rather than failing on an environment limitation.
final class PendingPageImporterTests: XCTestCase {

    func testFilterPendingDropsAlreadySavedURLs() {
        let pending = [
            PendingPageImporter.PendingSavedPage(url: "https://example.com/a", title: "A", savedAt: Date()),
            PendingPageImporter.PendingSavedPage(url: "https://example.com/b", title: "B", savedAt: Date()),
        ]
        let kept = PendingPageImporter.filterPending(pending, existingURLs: ["https://example.com/a"])
        XCTAssertEqual(kept.map(\.url), ["https://example.com/b"])
    }

    func testFilterPendingKeepsEverythingWhenLibraryIsEmpty() {
        let pending = [
            PendingPageImporter.PendingSavedPage(url: "https://example.com/a", title: "A", savedAt: Date()),
        ]
        XCTAssertEqual(PendingPageImporter.filterPending(pending, existingURLs: []).count, 1)
    }

    func testSafariPageToImportBuildsPage() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let page = PendingPageImporter.safariPageToImport(
            from: [
                "title": "Safari Article",
                "text": "Some article text here.",
                "url": "https://example.com/article",
                "date": date.timeIntervalSince1970,
            ],
            existingURLs: []
        )
        XCTAssertNotNil(page)
        XCTAssertEqual(page?.title, "Safari Article")
        XCTAssertEqual(page?.url, "https://example.com/article")
        XCTAssertEqual(page?.readerText, "Some article text here.")
        XCTAssertEqual(page?.savedAt, date)
    }

    func testSafariPageToImportFallsBackToURLAsTitle() {
        let page = PendingPageImporter.safariPageToImport(
            from: ["title": "", "text": "Text only.", "url": "https://example.com/x"],
            existingURLs: []
        )
        XCTAssertEqual(page?.title, "https://example.com/x")
    }

    func testSafariPageToImportReturnsNilForEmptyOrDuplicate() {
        XCTAssertNil(PendingPageImporter.safariPageToImport(from: [:], existingURLs: []))
        XCTAssertNil(PendingPageImporter.safariPageToImport(
            from: ["title": "", "text": "", "url": "https://example.com/x"],
            existingURLs: []
        ))
        XCTAssertNil(PendingPageImporter.safariPageToImport(
            from: ["title": "T", "text": "Text", "url": "https://example.com/x"],
            existingURLs: ["https://example.com/x"]
        ))
    }

    // importPendingPages is @MainActor, so this test must be too.
    @MainActor
    func testImportPendingPagesRoundTrip() throws {
        guard let defaults = UserDefaults(suiteName: PendingPageImporter.appGroupID) else {
            throw XCTSkip("App Group suite is not available on this test host (no entitlement) — import round trip cannot run here.")
        }
        defer {
            defaults.removeObject(forKey: PendingPageImporter.pendingPagesKey)
            defaults.removeObject(forKey: PendingPageImporter.latestSafariPageKey)
        }
        let container = try ModelContainer(
            for: SavedPage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        context.insert(SavedPage(url: "https://example.com/kept", title: "Kept", readerText: "", excerpt: ""))

        let pending = [
            PendingPageImporter.PendingSavedPage(url: "https://example.com/kept", title: "Kept again", savedAt: Date()),
            PendingPageImporter.PendingSavedPage(url: "https://example.com/new", title: "New", savedAt: Date()),
        ]
        defaults.set(try JSONEncoder().encode(pending), forKey: PendingPageImporter.pendingPagesKey)
        defaults.set(
            ["title": "Safari", "text": "Safari text", "url": "https://example.com/safari", "date": Date().timeIntervalSince1970],
            forKey: PendingPageImporter.latestSafariPageKey
        )

        PendingPageImporter.importPendingPages(modelContext: context)

        let pages = try context.fetch(FetchDescriptor<SavedPage>())
        let urls = Set(pages.map(\.url))
        // The duplicate "kept" URL is imported once; the new queue page
        // and the Safari page are both imported.
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(urls.contains("https://example.com/kept"))
        XCTAssertTrue(urls.contains("https://example.com/new"))
        XCTAssertTrue(urls.contains("https://example.com/safari"))
        // Imported entries are removed from the queue.
        XCTAssertNil(defaults.data(forKey: PendingPageImporter.pendingPagesKey))
        XCTAssertNil(defaults.dictionary(forKey: PendingPageImporter.latestSafariPageKey))
    }
}
