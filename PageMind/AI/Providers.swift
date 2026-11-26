import Foundation

// MARK: - OpenAI-compatible provider
// Covers OpenAI, Groq, Ollama, custom, and OpenRouter via ProviderConfig.

struct OpenAICompatibleProvider: AIProvider {
    let config: ProviderConfig

    init(config: ProviderConfig) {
        self.config = config
    }

    /// The API key is resolved by the caller (Keychain) and passed in here.
    /// This provider never reads the Keychain itself.
    var apiKey: String? = nil

    init(config: ProviderConfig, apiKey: String?) {
        self.config = config
        self.apiKey = apiKey
    }

    var id: String { config.kind.rawValue }
    var displayName: String { config.kind.displayName }
    var defaultBaseURL: String { config.kind.defaultBaseURL }
    var requiresKey: Bool { config.kind.requiresKey }
    var defaultModel: String { config.kind.defaultModel }
    var supportsVision: Bool { true }

    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?
    ) -> AsyncThrowingStream<String, Error> {
        OpenAICompatibleClient(baseURL: config.baseURL, apiKey: apiKey)
            .streamChat(messages: messages, model: model, systemPrompt: systemPrompt)
    }

    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?,
        images: [Data]
    ) -> AsyncThrowingStream<String, Error> {
        OpenAICompatibleClient(baseURL: config.baseURL, apiKey: apiKey)
            .streamChat(messages: messages, model: model, systemPrompt: systemPrompt, images: images)
    }
}

// MARK: - Anthropic provider

struct AnthropicProvider: AIProvider {
    let config: ProviderConfig
    let apiKey: String?

    init(config: ProviderConfig, apiKey: String?) {
        self.config = config
        self.apiKey = apiKey
    }

    var id: String { "anthropic" }
    var displayName: String { "Anthropic" }
    var defaultBaseURL: String { "https://api.anthropic.com" }
    var requiresKey: Bool { true }
    var defaultModel: String { "claude-sonnet-4-5" }
    var supportsVision: Bool { true }

    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?
    ) -> AsyncThrowingStream<String, Error> {
        streamChat(messages: messages, model: model, systemPrompt: systemPrompt, images: [])
    }

    /// Vision: images are attached to the last user message as base64
    /// image content blocks (Anthropic Messages API shape).
    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?,
        images: [Data]
    ) -> AsyncThrowingStream<String, Error> {
        // Plain tuples before the Task: ChatMessage is a SwiftData @Model
        // (not Sendable), and the producer Task's closure must be @Sendable.
        let plainMessages = messages.map { (role: $0.role, content: $0.content) }
        return AsyncThrowingStream { continuation in
            // Cancellation: abandoning the stream cancels the producer task
            // (see OpenAICompatibleClient) so the URLSession work ends.
            let task = Task {
                do {
                    guard let apiKey, !apiKey.isEmpty else {
                        throw AIError.missingAPIKey
                    }
                    guard let url = URL(string: config.baseURL + "/v1/messages") else {
                        throw AIError.invalidURL
                    }
                    var apiMessages: [[String: Any]] = []
                    for (index, message) in plainMessages.enumerated() {
                        let role = message.role == "assistant" ? "assistant" : "user"
                        var content: [[String: Any]] = [["type": "text", "text": message.content]]
                        let isLastUserMessage = role == "user" && index == messages.lastIndex(where: { $0.role != "assistant" })
                        if isLastUserMessage {
                            for imageData in images {
                                content.append([
                                    "type": "image",
                                    "source": [
                                        "type": "base64",
                                        "media_type": "image/jpeg",
                                        "data": imageData.base64EncodedString(),
                                    ],
                                ])
                            }
                        }
                        apiMessages.append(["role": role, "content": content])
                    }
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "messages": apiMessages,
                        "stream": true,
                    ]
                    if let systemPrompt, !systemPrompt.isEmpty {
                        body["system"] = systemPrompt
                    }
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200..<300).contains(httpResponse.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw AIError.httpError(statusCode: status, message: nil)
                    }
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              json["type"] as? String == "content_block_delta",
                              let delta = json["delta"] as? [String: Any],
                              let text = delta["text"] as? String,
                              !text.isEmpty else { continue }
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error as? AIError ?? AIError.networkError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Gemini provider

struct GeminiProvider: AIProvider {
    let config: ProviderConfig
    let apiKey: String?

    init(config: ProviderConfig, apiKey: String?) {
        self.config = config
        self.apiKey = apiKey
    }

    var id: String { "gemini" }
    var displayName: String { "Google Gemini" }
    var defaultBaseURL: String { "https://generativelanguage.googleapis.com/v1beta" }
    var requiresKey: Bool { true }
    var defaultModel: String { "gemini-2.5-flash" }
    var supportsVision: Bool { true }

    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?
    ) -> AsyncThrowingStream<String, Error> {
        streamChat(messages: messages, model: model, systemPrompt: systemPrompt, images: [])
    }

    /// Vision: images are attached to the last user message as
    /// `inline_data` parts (Gemini generateContent shape).
    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?,
        images: [Data]
    ) -> AsyncThrowingStream<String, Error> {
        // Plain tuples before the Task: ChatMessage is a SwiftData @Model
        // (not Sendable), and the producer Task's closure must be @Sendable.
        let plainMessages = messages.map { (role: $0.role, content: $0.content) }
        return AsyncThrowingStream { continuation in
            // Cancellation: abandoning the stream cancels the producer task
            // (see OpenAICompatibleClient) so the URLSession work ends.
            let task = Task {
                do {
                    guard let apiKey, !apiKey.isEmpty else {
                        throw AIError.missingAPIKey
                    }
                    // Auth: the API key travels in the `x-goog-api-key` header, NOT in
                    // the URL. Google's current Gemini API docs authenticate with this
                    // header (see ai.google.dev/gemini-api/docs, "generate content"
                    // quickstart: `curl ... -H "x-goog-api-key: $GEMINI_API_KEY"`).
                    // The `?key=` query form is a legacy pattern and puts the key in
                    // URLs, where it can land in logs, history and referrers.
                    let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard let url = URL(string: "\(base)/models/\(model):streamGenerateContent?alt=sse") else {
                        throw AIError.invalidURL
                    }
                    var contents: [[String: Any]] = []
                    if let systemPrompt, !systemPrompt.isEmpty {
                        contents.append([
                            "role": "user",
                            "parts": [["text": "System instructions: \(systemPrompt)"]],
                        ])
                    }
                    for (index, message) in plainMessages.enumerated() {
                        let role = message.role == "assistant" ? "model" : "user"
                        var parts: [[String: Any]] = [["text": message.content]]
                        let isLastUserMessage = role == "user" && index == messages.lastIndex(where: { $0.role != "assistant" })
                        if isLastUserMessage {
                            for imageData in images {
                                parts.append([
                                    "inline_data": [
                                        "mime_type": "image/jpeg",
                                        "data": imageData.base64EncodedString(),
                                    ],
                                ])
                            }
                        }
                        contents.append(["role": role, "parts": parts])
                    }
                    let body: [String: Any] = ["contents": contents]
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200..<300).contains(httpResponse.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        throw AIError.httpError(statusCode: status, message: nil)
                    }
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let candidates = json["candidates"] as? [[String: Any]],
                              let first = candidates.first,
                              let content = first["content"] as? [String: Any],
                              let parts = content["parts"] as? [[String: Any]] else { continue }
                        for part in parts {
                            if let text = part["text"] as? String, !text.isEmpty {
                                continuation.yield(text)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error as? AIError ?? AIError.networkError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
