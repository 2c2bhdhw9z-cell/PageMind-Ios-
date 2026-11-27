import Foundation
import SwiftData

// MARK: - Chat

@Model
final class ChatMessage {
    var id: UUID
    var role: String // "user" | "assistant" | "system"
    var content: String
    var createdAt: Date
    var citationsJSON: String // JSON-encoded [SourceCitation], empty string when none

    // Inverse of Chat.messages. The @Relationship lives on Chat.messages
    // only: declaring it on both sides makes the compiler report a
    // circular reference while expanding the macro.
    var chat: Chat?

    init(
        id: UUID = UUID(),
        role: String,
        content: String,
        createdAt: Date = Date(),
        citationsJSON: String = ""
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.citationsJSON = citationsJSON
    }

    var citations: [SourceCitation] {
        get {
            guard !citationsJSON.isEmpty,
                  let data = citationsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([SourceCitation].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let string = String(data: data, encoding: .utf8) {
                citationsJSON = string
            } else {
                citationsJSON = ""
            }
        }
    }
}

@Model
final class Chat {
    var id: UUID
    var title: String
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.chat)
    var messages: [ChatMessage]

    var attachedPageIDs: [String]
    var attachedPDFNames: [String]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        messages: [ChatMessage] = [],
        attachedPageIDs: [String] = [],
        attachedPDFNames: [String] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.messages = messages
        self.attachedPageIDs = attachedPageIDs
        self.attachedPDFNames = attachedPDFNames
    }
}

// MARK: - Saved pages & collections

@Model
final class SavedPage {
    var id: UUID
    var url: String
    var title: String
    var readerText: String
    var excerpt: String
    var savedAt: Date
    var collectionID: UUID?
    var tags: [String]
    /// Starred by the user in the Library (filter pill "Favorites").
    /// Added with a default so existing saved pages migrate as unfavorited.
    var isFavorite: Bool = false

    init(
        id: UUID = UUID(),
        url: String,
        title: String,
        readerText: String = "",
        excerpt: String = "",
        savedAt: Date = Date(),
        collectionID: UUID? = nil,
        tags: [String] = [],
        isFavorite: Bool = false
    ) {
        self.id = id
        self.url = url
        self.title = title
        self.readerText = readerText
        self.excerpt = excerpt
        self.savedAt = savedAt
        self.collectionID = collectionID
        self.tags = tags
        self.isFavorite = isFavorite
    }

    /// URL-based kind, for the Library filter pills. There is no stored
    /// kind field: a saved page is an image when its URL points at an
    /// image file, and a file when it points at a document or is a
    /// PageMind note (Morning Brief, Deep Research report).
    var isImageURL: Bool {
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg"].contains(ext)
    }

    var isFileURL: Bool {
        if url.hasPrefix("pagemind://") { return true }
        let ext = URL(string: url)?.pathExtension.lowercased() ?? ""
        return ["pdf", "doc", "docx", "txt", "md", "csv", "zip", "epub"].contains(ext)
    }
}

@Model
final class CollectionModel {
    var id: UUID
    var name: String
    var createdAt: Date
    var systemPrompt: String

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        systemPrompt: String = ""
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.systemPrompt = systemPrompt
    }
}

// MARK: - Plain value types

struct SourceCitation: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var title: String
    var url: String

    init(title: String, url: String) {
        self.title = title
        self.url = url
    }

    // Decode without requiring an id in stored JSON.
    enum CodingKeys: String, CodingKey {
        case title, url
    }
}

enum HighlightAction: String, CaseIterable, Identifiable {
    case explain
    case tldr
    case rewrite
    case translate
    case simplify

    var id: String { rawValue }

    var label: String {
        switch self {
        case .explain: return "Explain"
        case .tldr: return "TL;DR"
        case .rewrite: return "Rewrite"
        case .translate: return "Translate"
        case .simplify: return "Simplify"
        }
    }
}
