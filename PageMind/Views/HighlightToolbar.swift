import SwiftUI

/// Highlight toolbar: Explain / TL;DR / Rewrite / Translate / Simplify.
///
/// This is UI only. Tapping a button calls the supplied closure with the
/// selected text and the chosen action; the actual AI call lives in
/// ChatViewModel (other builder).
///
/// Assumes HighlightAction (other builder) is an enum with cases
/// explain, tldr, rewrite, translate, simplify.
struct HighlightToolbar: View {
    let text: String
    let onHighlight: (String, HighlightAction) -> Void

    private let actions: [(title: String, action: HighlightAction)] = [
        ("Explain", .explain),
        ("TL;DR", .tldr),
        ("Rewrite", .rewrite),
        ("Translate", .translate),
        ("Simplify", .simplify)
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(actions, id: \.title) { item in
                    Button(item.title) {
                        onHighlight(text, item.action)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal)
        }
    }
}

/// Build the prompt for a highlight action. The selected text should be
/// appended by the caller (see HighlightPresets in AppSettings).
/// `language` is used by the Translate action; other actions ignore it.
func highlightPrompt(for action: HighlightAction, language: String = "English") -> String {
    switch action {
    case .explain:
        return HighlightPresets.explain
    case .tldr:
        return HighlightPresets.tldr
    case .rewrite:
        return HighlightPresets.rewrite
    case .translate:
        return "Translate the following text into \(language). Preserve the meaning and tone, and return only the translation:\n\n"
    case .simplify:
        return HighlightPresets.simplify
    }
}
