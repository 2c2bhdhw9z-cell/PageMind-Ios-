import SwiftUI
import SwiftData

/// Library / Web Memory: the list of saved pages.
///
/// Search uses WebMemorySearch over the @Query SavedPage list. Pages can be
/// filtered by collection, opened as reader text in a sheet, and deleted
/// with swipe-to-delete. New collections are created from the sheet below.
///
/// SavedPage (other builder) exposes: title, excerpt and readerText as
/// non-optional Strings, tags, savedAt, and `collectionID: UUID?`
/// (no `collection` relationship). CollectionModel exposes `id: UUID`,
/// `name`, and `init(name:)`.
struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedPage.savedAt, order: .reverse) private var pages: [SavedPage]
    @Query(sort: \CollectionModel.name) private var collections: [CollectionModel]

    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @State private var selectedCollectionID: UUID?
    @State private var selectedPage: SavedPage?
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""

    private var searcher = WebMemorySearch()

    private var filteredPages: [SavedPage] {
        var result = pages
        if let id = selectedCollectionID {
            result = result.filter { $0.collectionID == id }
        }
        switch filter {
        case .all:
            break
        case .favorites:
            result = result.filter { $0.isFavorite }
        case .images:
            result = result.filter { $0.isImageURL }
        case .files:
            result = result.filter { $0.isFileURL }
        }
        return searcher.search(query: searchText, in: result)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScreenHeader(title: "Library") {
                    TopBarIconButton(systemImage: "folder.badge.plus", accessibilityLabel: "New collection") {
                        showingNewCollection = true
                    }
                }
                SearchField(text: $searchText, prompt: "Search saved pages")
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                filterPills
                Group {
                    if pages.isEmpty {
                        emptyState
                    } else if filteredPages.isEmpty {
                        ContentUnavailableView(
                            "No matching pages",
                            systemImage: "magnifyingglass",
                            description: Text("Try a different search, filter, or collection.")
                        )
                    } else {
                        List {
                            ForEach(filteredPages) { page in
                                HStack(alignment: .top, spacing: 10) {
                                    IconChip(
                                        systemImage: page.isImageURL ? "photo" : page.isFileURL ? "doc.fill" : "globe",
                                        tint: PageMindDesign.brandIndigo.opacity(0.85)
                                    )

                                    Button { selectedPage = page } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(page.title)
                                                .font(.headline)
                                                .lineLimit(2)
                                            if !page.excerpt.isEmpty {
                                                Text(page.excerpt)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(2)
                                            }
                                            Text(page.savedAt, style: .date)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        page.isFavorite.toggle()
                                        try? modelContext.save()
                                    } label: {
                                        Image(systemName: page.isFavorite ? "star.fill" : "star")
                                            .foregroundStyle(page.isFavorite ? .yellow : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(
                                        page.isFavorite ? "Remove \(page.title) from favorites" : "Add \(page.title) to favorites"
                                    )
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        modelContext.delete(page)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(PageMindDesign.appBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selectedPage) { page in
                ReaderSheetView(page: page)
            }
            .sheet(isPresented: $showingNewCollection) {
                newCollectionSheet
            }
        }
    }

    /// Filter pills (All / Favorites / Images / Files), matching the
    /// Library filters SurfMind's web Library shows — over real saved
    /// pages, which SurfMind does not have. Images and files are
    /// classified from the page URL (see SavedPage.isImageURL /
    /// isFileURL); Favorites is the star on each row.
    private var filterPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                collectionMenu
                ForEach(LibraryFilter.allCases) { pill in
                    Button {
                        filter = pill
                    } label: {
                        Text(pill.label)
                            .font(.subheadline)
                            .bold(filter == pill)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                filter == pill
                                    ? PageMindDesign.brandIndigo
                                    : PageMindDesign.elevatedCard
                            )
                            .foregroundStyle(
                                filter == pill ? Color.white : Color.primary
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    /// Menu-style collection picker (replaces the old segmented control,
    /// which grew ugly once there were more than a few collections).
    /// Shows the current collection name, or "All pages".
    private var collectionMenu: some View {
        Menu {
            Picker("Collection", selection: $selectedCollectionID) {
                Text("All pages").tag(UUID?.none)
                ForEach(collections) { collection in
                    Text(collection.name).tag(UUID?.some(collection.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                Text(selectedCollectionName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .foregroundStyle(PageMindDesign.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().stroke(Color.primary.opacity(0.14), lineWidth: 1))
        }
        .accessibilityLabel("Collection: \(selectedCollectionName)")
    }

    private var selectedCollectionName: String {
        guard let id = selectedCollectionID,
              let collection = collections.first(where: { $0.id == id }) else {
            return "All pages"
        }
        return collection.name
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No pages saved yet",
            systemImage: "bookmark",
            description: Text("Open a page in the Browser and tap Save page. Then ask PageMind anything about it.")
        )
    }

    private var newCollectionSheet: some View {
        NavigationStack {
            Form {
                TextField("Collection name", text: $newCollectionName)
            }
            .navigationTitle("New collection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingNewCollection = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        modelContext.insert(CollectionModel(name: name))
                        newCollectionName = ""
                        showingNewCollection = false
                    }
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Reader sheet: shows the saved page's extracted text.
/// Internal (not private) so SearchView can reuse it.
struct ReaderSheetView: View {
    let page: SavedPage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(page.readerText.isEmpty ? (page.excerpt.isEmpty ? "No readable text was saved for this page." : page.excerpt) : page.readerText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Library filter pills

/// The Library filter pills (All / Favorites / Images / Files).
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case images
    case files

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .images: return "Images"
        case .files: return "Files"
        }
    }
}
