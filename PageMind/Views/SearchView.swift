import SwiftUI
import SwiftData

/// Search over Web Memory: keyword search across saved pages
/// (title x3, tags x2, page text x1), newest first. Tap a result to
/// read it; saving and asking about pages still happens in Library
/// and Chat.
struct SearchView: View {
    @Query(sort: \SavedPage.savedAt, order: .reverse) private var pages: [SavedPage]

    @State private var searchText = ""
    @State private var selectedPage: SavedPage?

    private var searcher = WebMemorySearch()

    private var results: [SavedPage] {
        searcher.search(query: searchText, in: pages)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScreenHeader(title: "Search")
                SearchField(text: $searchText, prompt: "Search saved pages")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                Group {
                    if pages.isEmpty {
                        ContentUnavailableView(
                            "No saved pages yet",
                            systemImage: "magnifyingglass",
                            description: Text("Save a page from the Browser, then search it here.")
                        )
                    } else if results.isEmpty {
                        ContentUnavailableView(
                            "No matching pages",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search.")
                        )
                    } else {
                        List {
                            ForEach(results) { page in
                                HStack(alignment: .top, spacing: 10) {
                                    IconChip(
                                        systemImage: page.isImageURL ? "photo" : page.isFileURL ? "doc.fill" : "globe",
                                        tint: PageMindDesign.brandIndigo.opacity(0.85)
                                    )

                                    Button { selectedPage = page } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(page.title.isEmpty ? page.url : page.title)
                                                .font(.headline)
                                                .lineLimit(2)
                                                .fixedSize(horizontal: false, vertical: true)
                                            if !page.excerpt.isEmpty {
                                                Text(page.excerpt)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                            Text(page.savedAt, style: .date)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .listRowBackground(PageMindDesign.elevatedCard)
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                        .background(PageMindDesign.appBackground)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PageMindDesign.appBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedPage) { page in
                ReaderSheetView(page: page)
            }
        }
    }
}
