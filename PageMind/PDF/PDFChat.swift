import Foundation
import PDFKit

/// Extracts plain text from a PDF so it can be used as chat context.
/// Enforces no chat-level policy here — the 10-PDF-per-chat limit is the
/// caller's job (see the note on `PDFAttachment` below).
struct PDFTextExtractor {
    /// Extracts text from up to `maxPages` pages (default 60).
    /// Returns "" for unreadable data, an encrypted/locked PDF, or a PDF
    /// with no extractable text (e.g. scanned images with no OCR layer).
    func extractText(from data: Data, maxPages: Int = 60) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        // A locked document reports no pages / no strings until unlocked.
        guard !document.isLocked else { return "" }

        let pageCount = min(document.pageCount, max(0, maxPages))
        var parts: [String] = []
        parts.reserveCapacity(pageCount)
        for index in 0..<pageCount {
            guard let page = document.page(at: index),
                  let text = page.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            parts.append(text)
        }
        return parts.joined(separator: "\n\n")
    }
}

/// One PDF attached to a chat, with its extracted text ready for context.
/// NOTE: PageMind allows at most 10 PDFs per chat. That limit is enforced
/// by the caller (the chat UI / view model) when attachments are added,
/// not here — this type just carries one attachment.
struct PDFAttachment: Identifiable, Hashable {
    var id: UUID = UUID()
    var fileName: String
    var text: String

    var charCount: Int { text.count }

    init(id: UUID = UUID(), fileName: String, text: String) {
        self.id = id
        self.fileName = fileName
        self.text = text
    }

    /// The attachment's text, truncated for use as chat context.
    func contextText(maxChars: Int = 12_000) -> String {
        truncateForContext(text, maxChars: maxChars)
    }
}

/// Truncates text to `maxChars` characters for chat context, cutting at a
/// word boundary where possible and noting the truncation.
func truncateForContext(_ text: String, maxChars: Int = 12_000) -> String {
    guard text.count > maxChars else { return text }
    let prefix = String(text.prefix(maxChars))
    if let lastSpace = prefix.lastIndex(of: " ") {
        return String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            + "\n\n[…truncated to \(maxChars) characters]"
    }
    return prefix + "\n\n[…truncated to \(maxChars) characters]"
}
