import Foundation

/// Non-streaming chat helpers, used by the Pro features (Browser Agent
/// planner, Morning Brief, Deep Research, model compare) which need one
/// complete answer rather than a token stream. All of them collect the
/// provider's AsyncThrowingStream into a single String.
///
/// Messages are plain `(role, content)` tuples — not ChatMessage —
/// so callers can use these helpers from `@Sendable` closures (e.g.
/// the compare view's task group). ChatMessage is a SwiftData @Model
/// class and is not Sendable.
enum ChatCompletion {

    /// Collects a full reply from any provider. Throws the provider's
    /// error (e.g. missing key, HTTP 401) so callers can surface it.
    static func collectText(
        provider: any AIProvider,
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        images: [Data] = []
    ) async throws -> String {
        let chatMessages = messages.map { ChatMessage(role: $0.role, content: $0.content) }
        var text = ""
        for try await token in provider.streamChat(
            messages: chatMessages,
            model: model,
            systemPrompt: systemPrompt,
            images: images
        ) {
            text += token
        }
        return text
    }

    /// Convenience: builds the provider from AppSettings, sends one user
    /// message, and returns the full reply text.
    static func ask(
        settings: AppSettings,
        prompt: String,
        systemPrompt: String? = nil
    ) async throws -> String {
        let config = settings.providerConfig
        let provider = ChatViewModel.provider(
            for: config,
            apiKey: settings.apiKey(for: config.kind)
        )
        return try await collectText(
            provider: provider,
            messages: [(role: "user", content: prompt)],
            model: settings.effectiveModel,
            systemPrompt: systemPrompt
        )
    }
}
