import Foundation
import SwiftData

/// Drives a single chat conversation: builds the system prompt + page
/// context, streams the assistant reply token by token, and records
/// messages on the current SwiftData Chat.
///
/// Provider wiring: call `configure(with:)` with the app's AppSettings
/// (Data/AppSettings.swift, other builder — verified: it exposes
/// `providerConfig`, `effectiveModel`, `systemPrompt`, and
/// `apiKey(for:)`). Until configured, the view model uses the OpenRouter
/// free default with no key, and `send` reports a clear error instead
/// of failing silently.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published var currentChat: Chat?
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming = false
    @Published var errorMessage: String?
    @Published var selectedModel: String = ModelCatalog.defaultModel

    /// Total page/PDF context budget, in characters.
    static let contextBudget = 12_000

    /// Whether the current provider can take image attachments.
    /// The *model* must also support vision; a text-only model returns a
    /// provider error, which surfaces as a chat error with a hint.
    var providerSupportsVision: Bool { provider.supportsVision }

    /// A short, actionable hint for the current error, or nil.
    /// Shown under the error text in ChatView.
    var errorHint: String? {
        guard let errorMessage else { return nil }
        if errorMessage.contains("No API key") {
            return "Add a key for this provider in Settings, or switch to OpenRouter free models."
        }
        if errorMessage.contains("401") {
            return "The provider rejected the key (401). Check the key in Settings — it may be wrong or revoked."
        }
        if errorMessage.contains("429") {
            return "Rate limited (429). Wait a minute, or switch to a different model."
        }
        if errorMessage.contains("404") {
            return "Model not found (404). Pick a different model — free model names change often."
        }
        return nil
    }

    private var provider: any AIProvider = OpenAICompatibleProvider(
        config: ProviderConfig(kind: .openRouter)
    )
    private var providerAPIKey: String?
    private var customSystemPrompt: String?
    private var modelContext: ModelContext?
    private var streamingTask: Task<Void, Never>?

    init(chat: Chat? = nil, modelContext: ModelContext? = nil) {
        self.currentChat = chat
        self.modelContext = modelContext
        if let chat {
            self.messages = chat.messages.sorted { $0.createdAt < $1.createdAt }
        }
    }

    // MARK: - Setup

    func bind(chat: Chat, modelContext: ModelContext? = nil) {
        currentChat = chat
        self.modelContext = modelContext
        messages = chat.messages.sorted { $0.createdAt < $1.createdAt }
    }

    func configure(with settings: AppSettings) {
        let config = settings.providerConfig
        providerAPIKey = settings.apiKey(for: config.kind)
        provider = Self.provider(for: config, apiKey: providerAPIKey)
        // effectiveModel already resolves the custom-provider model override.
        selectedModel = settings.effectiveModel
        if !settings.systemPrompt.isEmpty {
            customSystemPrompt = settings.systemPrompt
        }
    }

    /// Direct configuration without AppSettings (tests / previews).
    func configure(provider: any AIProvider, model: String) {
        self.provider = provider
        self.selectedModel = model
    }

    static func provider(for config: ProviderConfig, apiKey: String?) -> any AIProvider {
        switch config.kind {
        case .anthropic:
            return AnthropicProvider(config: config, apiKey: apiKey)
        case .gemini:
            return GeminiProvider(config: config, apiKey: apiKey)
        default:
            return OpenAICompatibleProvider(config: config, apiKey: apiKey)
        }
    }

    // MARK: - Sending

    /// Sends a prompt with optional page context, PDF attachment text,
    /// image attachments (vision), and web-search results. Page text is
    /// truncated so all context together stays within ~12,000 characters.
    func send(
        prompt: String,
        contextPages: [SavedPage] = [],
        attachments: [String] = [],
        webSearchResults: [SourceCitation] = [],
        imageAttachments: [ChatImageAttachment] = []
    ) {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isStreaming else { return }
        errorMessage = nil

        if currentChat == nil {
            currentChat = Chat(title: Self.title(for: trimmedPrompt))
            if let chat = currentChat {
                modelContext?.insert(chat)
            }
        }

        let userMessage = ChatMessage(role: "user", content: trimmedPrompt)
        append(userMessage)

        let assistantMessage = ChatMessage(role: "assistant", content: "")
        append(assistantMessage)
        if !webSearchResults.isEmpty {
            assistantMessage.citations = webSearchResults
        }

        let systemPrompt = Self.buildSystemPrompt(
            contextPages: contextPages,
            attachments: attachments,
            webSearchResults: webSearchResults,
            basePrompt: customSystemPrompt
        )

        isStreaming = true
        // Exclude the empty assistant placeholder just appended.
        let history = Array(messages.dropLast())
        let images = imageAttachments.map(\.jpegData)
        let provider = self.provider
        let model = selectedModel
        // The stream is created *inside* the task (not before it): when
        // the task is cancelled, the for-await loop ends, the stream is
        // abandoned, and the provider's onTermination handler cancels its
        // producer task, so the URLSession work actually stops. Creating
        // the stream outside the task (the old code) left the producer
        // task unlinked and it could linger after Stop was tapped.
        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await token in provider.streamChat(
                    messages: history,
                    model: model,
                    systemPrompt: systemPrompt,
                    images: images
                ) {
                    if Task.isCancelled { break }
                    assistantMessage.content += token
                }
                if Task.isCancelled, assistantMessage.content.isEmpty {
                    assistantMessage.content = "Stopped."
                }
            } catch is CancellationError {
                if assistantMessage.content.isEmpty {
                    assistantMessage.content = "Stopped."
                }
            } catch {
                if Task.isCancelled {
                    if assistantMessage.content.isEmpty {
                        assistantMessage.content = "Stopped."
                    }
                } else {
                    self.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    if assistantMessage.content.isEmpty {
                        assistantMessage.content = "Sorry — that reply failed. \(self.errorMessage ?? "")"
                    }
                }
            }
            self.isStreaming = false
            self.saveIfNeeded()
        }
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        isStreaming = false
    }

    func newChat() {
        cancelStreaming()
        currentChat = nil
        messages = []
        errorMessage = nil
    }

    // MARK: - Quick actions (highlight presets)

    /// Local fallback presets, used only if HighlightPresets ever returns
    /// an empty prompt. The canonical source is HighlightPresets
    /// (Data/AppSettings.swift, other builder).
    private static let fallbackPresets: [HighlightAction: String] = [
        .explain: "Explain the following text clearly and concisely:\n\n",
        .tldr: "Give a short TL;DR summary of the following text:\n\n",
        .rewrite: "Rewrite the following text more clearly, keeping its meaning:\n\n",
        .translate: "Translate the following text into English:\n\n",
        .simplify: "Simplify the following text so it is easy to understand:\n\n",
    ]

    func quickAction(_ action: HighlightAction, text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let prompt = HighlightPresets.prompt(for: action, text: cleaned)
        send(prompt: prompt.isEmpty
            ? (Self.fallbackPresets[action] ?? "Help with the following text:\n\n") + cleaned
            : prompt)
    }

    // MARK: - Prompt building

    static func buildSystemPrompt(
        contextPages: [SavedPage],
        attachments: [String],
        webSearchResults: [SourceCitation],
        basePrompt: String? = nil
    ) -> String {
        let base = (basePrompt?.isEmpty == false) ? basePrompt! : "You are PageMind, a helpful page-aware AI chat assistant. Answer using the provided page, PDF, image, and web-search context when relevant. If the context does not contain the answer, say so instead of inventing details. Cite sources by title when you use web-search results."
        var parts: [String] = [base]

        var budget = contextBudget
        var contextBlocks: [String] = []

        for page in contextPages where budget > 0 {
            let text = page.readerText.isEmpty ? page.excerpt : page.readerText
            guard !text.isEmpty else { continue }
            let taken = String(text.prefix(budget))
            contextBlocks.append("Page \"\(page.title)\" (\(page.url)):\n\(taken)")
            budget -= taken.count
        }
        for attachment in attachments where budget > 0 {
            guard !attachment.isEmpty else { continue }
            let taken = String(attachment.prefix(budget))
            contextBlocks.append("Attached document:\n\(taken)")
            budget -= taken.count
        }
        if !contextBlocks.isEmpty {
            parts.append("Context:\n" + contextBlocks.joined(separator: "\n\n---\n\n"))
        }

        if !webSearchResults.isEmpty {
            let sources = webSearchResults
                .map { "- \($0.title): \($0.url)" }
                .joined(separator: "\n")
            parts.append("Web search results:\n\(sources)")
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    private func append(_ message: ChatMessage) {
        messages.append(message)
        currentChat?.messages.append(message)
        if let modelContext {
            modelContext.insert(message)
        }
        saveIfNeeded()
    }

    private func saveIfNeeded() {
        guard let modelContext else { return }
        do {
            try modelContext.save()
        } catch {
            errorMessage = "Could not save this chat: \(error.localizedDescription)"
        }
    }

    private static func title(for prompt: String) -> String {
        let firstLine = prompt.components(separatedBy: .newlines).first ?? prompt
        return String(firstLine.prefix(60))
    }
}
