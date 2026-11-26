import Foundation
import SwiftUI

/// App-wide user settings, persisted with @AppStorage.
///
/// There is exactly one instance: `AppSettings.shared`, created at app
/// launch and injected into the view hierarchy with `.environmentObject`.
/// Views must use `@EnvironmentObject` to read it — do not create new
/// `AppSettings()` instances in views. (The old code had one instance per
/// view; values stayed in sync only because they share @AppStorage keys,
/// which is fragile and hides the real source of truth.)
///
/// API keys themselves are never stored here — they live in the Keychain
/// (see KeychainStore). Only a boolean flag records whether a Brave key exists.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("selectedProviderRaw") var selectedProviderRaw: String = AIProviderKind.openRouter.rawValue
    @AppStorage("selectedModel") var selectedModel: String = "openrouter/free"
    @AppStorage("systemPrompt") var systemPrompt: String = "You are PageMind, a helpful reading companion. Answer using the page content provided. Cite sources when you quote the page."
    @AppStorage("hasSeenOnboarding") var hasSeenOnboarding: Bool = false
    @AppStorage("braveAPIKeyID") var braveAPIKeyID: Bool = false
    @AppStorage("ollamaBaseURL") var ollamaBaseURL: String = "http://localhost:11434/v1"
    @AppStorage("customBaseURL") var customBaseURL: String = ""
    @AppStorage("customModel") var customModel: String = ""

    /// The selected provider as a typed value. Falls back to OpenRouter
    /// if the stored raw value no longer matches a known case.
    var selectedProvider: AIProviderKind {
        get { AIProviderKind(rawValue: selectedProviderRaw) ?? .openRouter }
        set { selectedProviderRaw = newValue.rawValue }
    }

    /// Whether a Brave Search key is stored in the Keychain.
    /// This is a boolean only — the key itself is never read into settings.
    var hasBraveKey: Bool {
        KeychainStore.hasKey(KeychainStore.brave)
    }

    /// The API key for the currently selected provider, read from the Keychain.
    var currentProviderKey: String? {
        apiKey(for: selectedProvider)
    }

    /// The API key for a given provider, read from the Keychain.
    /// Used by ChatViewModel.configure(with:) as `settings.apiKey(for:)`.
    func apiKey(for kind: AIProviderKind) -> String? {
        switch kind {
        case .openRouter: return KeychainStore.load(key: KeychainStore.openRouter)
        case .openAI: return KeychainStore.load(key: KeychainStore.openAI)
        case .anthropic: return KeychainStore.load(key: KeychainStore.anthropic)
        case .gemini: return KeychainStore.load(key: KeychainStore.gemini)
        case .groq: return KeychainStore.load(key: KeychainStore.groq)
        case .ollama, .custom: return nil
        }
    }

    /// The Brave Search API key, read from the Keychain (nil if not set).
    /// ChatView passes this as `braveAPIKey:` to WebSearchService.
    var braveAPIKey: String? {
        KeychainStore.load(key: KeychainStore.brave)
    }

    /// Effective base URL for the selected provider, if it uses one.
    var effectiveBaseURL: String? {
        switch selectedProvider {
        case .ollama: return ollamaBaseURL
        case .custom: return customBaseURL.isEmpty ? nil : customBaseURL
        default: return nil
        }
    }

    /// Effective model id for the selected provider.
    var effectiveModel: String {
        if selectedProvider == .custom, !customModel.isEmpty {
            return customModel
        }
        return selectedModel
    }

    /// The Keychain item ID for the currently selected provider, if any.
    /// ProviderConfig stores this ID — never the key itself.
    var currentProviderKeyID: String? {
        switch selectedProvider {
        case .openRouter: return KeychainStore.openRouter
        case .openAI: return KeychainStore.openAI
        case .anthropic: return KeychainStore.anthropic
        case .gemini: return KeychainStore.gemini
        case .groq: return KeychainStore.groq
        case .ollama, .custom: return nil
        }
    }

    /// The provider configuration used by the chat layer.
    /// NOTE: this is a computed *property*, not a method — ChatViewModel
    /// reads it as `settings.providerConfig`. ProviderConfig (other builder)
    /// is `init(kind:baseURL:apiKeyID:model:)`; it holds the Keychain key ID,
    /// not the key value, and no system prompt (passed separately at chat time).
    var providerConfig: ProviderConfig {
        ProviderConfig(
            kind: selectedProvider,
            baseURL: effectiveBaseURL,
            apiKeyID: currentProviderKeyID,
            model: effectiveModel
        )
    }
}

/// Ready-made prompts for the highlight toolbar actions.
enum HighlightPresets {
    static let explain = "Explain the following text in clear, simple language. Keep the original meaning, define any technical terms, and use short paragraphs:\n\n"
    static let tldr = "Summarise the following text as a TL;DR: no more than 3 bullet points, covering only the most important points:\n\n"
    static let rewrite = "Rewrite the following text to be clearer and more concise, keeping the same meaning and tone. Return only the rewritten text:\n\n"
    static let translate = "Translate the following text into the requested language. Preserve the meaning and tone, and return only the translation:\n\n"
    static let simplify = "Simplify the following text so a 12-year-old can understand it. Use plain words and short sentences, without losing the key facts:\n\n"

    static func prompt(for action: HighlightAction) -> String {
        switch action {
        case .explain: return explain
        case .tldr: return tldr
        case .rewrite: return rewrite
        case .translate: return translate
        case .simplify: return simplify
        }
    }

    /// Full prompt for an action with the selected text appended.
    /// This is the form ChatViewModel.quickAction expects
    /// (`HighlightPresets.prompt(for:text:)`).
    static func prompt(for action: HighlightAction, text: String) -> String {
        prompt(for: action) + text
    }
}
