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

    // MARK: - Model-picker favourites

    @AppStorage("favoriteModelsJSON") private var favoriteModelsJSON: String = "[]"

    /// Model ids the user starred in the model picker. Persisted as a
    /// JSON array so ids containing commas still round-trip.
    var favoriteModels: Set<String> {
        get {
            let decoded = (try? JSONDecoder().decode([String].self, from: Data(favoriteModelsJSON.utf8))) ?? []
            return Set(decoded)
        }
        set {
            objectWillChange.send()
            favoriteModelsJSON = (try? String(
                data: JSONEncoder().encode(Array(newValue).sorted()),
                encoding: .utf8
            )) ?? "[]"
        }
    }

    func toggleFavoriteModel(_ id: String) {
        var favorites = favoriteModels
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
        favoriteModels = favorites
    }

    // MARK: - Appearance

    @AppStorage("appThemeRaw") var appThemeRaw: String = AppTheme.auto.rawValue
    @AppStorage("appFontSizeRaw") var appFontSizeRaw: String = AppFontSize.medium.rawValue
    @AppStorage("appLanguageRaw") var appLanguageRaw: String = "system"

    var appTheme: AppTheme {
        get { AppTheme(rawValue: appThemeRaw) ?? .auto }
        set { appThemeRaw = newValue.rawValue }
    }

    /// nil = follow the system (Auto).
    var preferredColorScheme: ColorScheme? { appTheme.colorScheme }

    var appFontSize: AppFontSize {
        get { AppFontSize(rawValue: appFontSizeRaw) ?? .medium }
        set { appFontSizeRaw = newValue.rawValue }
    }

    var preferredTypeSize: DynamicTypeSize { appFontSize.dynamicTypeSize }

    /// The locale the app runs in. "system" follows the device; any other
    /// code is applied to system-formatted content (dates, numbers).
    /// PageMind's own strings are English-only, so this does not translate
    /// the interface — the Settings screen says so honestly.
    var preferredLocale: Locale {
        appLanguageRaw == "system" ? .autoupdatingCurrent : Locale(identifier: appLanguageRaw)
    }

    // MARK: - Skills (system-prompt presets)

    @AppStorage("customSkillPresetsJSON") private var customSkillPresetsJSON: String = "[]"

    /// User-created skill presets (name + prompt). Built-ins live in
    /// `SkillPreset.builtIns` and are not stored.
    var customSkillPresets: [SkillPreset] {
        get {
            (try? JSONDecoder().decode([SkillPreset].self, from: Data(customSkillPresetsJSON.utf8))) ?? []
        }
        set {
            objectWillChange.send()
            customSkillPresetsJSON = (try? String(
                data: JSONEncoder().encode(newValue),
                encoding: .utf8
            )) ?? "[]"
        }
    }

    var allSkillPresets: [SkillPreset] {
        SkillPreset.builtIns + customSkillPresets
    }

    /// The preset whose prompt is the current system prompt, if any.
    var activeSkillPreset: SkillPreset? {
        allSkillPresets.first { $0.prompt == systemPrompt }
    }

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
enum HighlightPresets {    static let explain = "Explain the following text in clear, simple language. Keep the original meaning, define any technical terms, and use short paragraphs:\n\n"
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

// MARK: - Appearance choices

/// Theme setting: Auto follows the device, Light / Dark force it.
/// Applied at the app root with `.preferredColorScheme`.
enum AppTheme: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Text-size setting, applied at the app root with `.dynamicTypeSize`.
enum AppFontSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .extraLarge: return .xLarge
        }
    }
}

/// Display-language choices. The codes are BCP 47 identifiers applied
/// with `.environment(\.locale, …)`; "system" follows the device.
/// PageMind's own strings are English-only — the language changes
/// system-formatted content (dates, numbers) only.
enum AppLanguage {
    static let choices: [(code: String, label: String)] = [
        ("system", "System"),
        ("en", "English"),
        ("es", "Español"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("ja", "日本語"),
        ("pt", "Português"),
    ]
}

// MARK: - Skills (system-prompt presets)

/// A saved system-prompt preset. Built-ins are constants below;
/// user-created ones are stored in AppSettings as JSON.
struct SkillPreset: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var prompt: String
    /// Built-ins cannot be edited or deleted.
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, prompt: String, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isBuiltIn = isBuiltIn
    }

    /// The four built-in presets. Prompt text is PageMind's own wording.
    static let builtIns: [SkillPreset] = [
        SkillPreset(
            name: "Web Search",
            prompt: "You are PageMind's research assistant. When the user asks about current events or facts, use the web search results provided as context. Cite every factual claim with its source. If the search results don't contain the answer, say so clearly instead of guessing.",
            isBuiltIn: true
        ),
        SkillPreset(
            name: "Fact Check",
            prompt: "You are a careful fact-checker. Check each claim in the user's message or the provided page against the context given. For each claim, say whether it is supported, contradicted, or unverifiable, and quote the evidence. Do not add claims of your own.",
            isBuiltIn: true
        ),
        SkillPreset(
            name: "Deep Research",
            prompt: "You are a thorough research assistant. Read all the provided pages and search results, compare what they say, and write a structured report with headings, key findings, points of disagreement, and a sources list. Prefer primary sources and say when the evidence is thin.",
            isBuiltIn: true
        ),
        SkillPreset(
            name: "Paper Reader",
            prompt: "You are an expert at reading academic papers and long documents. Summarise the provided document: its main argument, methods, key results, and limitations. Explain technical terms in plain language and note anything the authors leave unclear.",
            isBuiltIn: true
        ),
    ]
}
