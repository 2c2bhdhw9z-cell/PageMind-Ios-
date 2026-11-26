import Foundation

/// URLSession client for OpenAI-compatible `/chat/completions` endpoints.
/// Used by OpenRouter, OpenAI, Groq, Ollama, LM Studio, and custom providers.
struct OpenAICompatibleClient: Sendable {
    let baseURL: String
    let apiKey: String?
    private let session: URLSession

    init(baseURL: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Streaming chat

    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?,
        images: [Data] = []
    ) -> AsyncThrowingStream<String, Error> {
        // Plain tuples before the Task: ChatMessage is a SwiftData @Model
        // (not Sendable), and the producer Task's closure must be
        // @Sendable. Tuples of Strings are Sendable, so the Task captures
        // only those.
        let plainMessages = messages.map { (role: $0.role, content: $0.content) }
        return AsyncThrowingStream { continuation in
            // Cancellation: when the consumer stops iterating (e.g. the user
            // taps Stop), the stream is abandoned and onTermination fires,
            // cancelling the producer task so the URLSession work ends
            // instead of lingering. The same pattern is used by the inner
            // token stream below and by the Anthropic / Gemini providers.
            let task = Task {
                do {
                    for try await token in try await streamTokens(
                        messages: plainMessages,
                        model: model,
                        systemPrompt: systemPrompt,
                        images: images
                    ) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamTokens(
        messages: [(role: String, content: String)],
        model: String,
        systemPrompt: String?,
        images: [Data] = []
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw AIError.invalidURL
        }

        // Messages are [String: Any] so a user message can carry vision
        // content parts (text + image_url) when images are attached.
        var payloadMessages: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty {
            payloadMessages.append(["role": "system", "content": systemPrompt])
        }
        for (index, message) in messages.enumerated() {
            let role = message.role == "assistant" ? "assistant" : "user"
            let isLastUserMessage = role == "user" && index == messages.lastIndex(where: { $0.role != "assistant" })
            if isLastUserMessage, !images.isEmpty {
                var parts: [[String: Any]] = [["type": "text", "text": message.content]]
                for imageData in images {
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"],
                    ])
                }
                payloadMessages.append(["role": role, "content": parts])
            } else {
                payloadMessages.append(["role": role, "content": message.content])
            }
        }

        let body: [String: Any] = [
            "model": model,
            "messages": payloadMessages,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // OpenRouter attribution headers (harmless for other providers).
        request.setValue("PageMind", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw AIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // Read the error body for a useful message, if any.
            var errorText = ""
            do {
                for try await line in bytes.lines {
                    errorText += line
                    if errorText.count > 2_000 { break }
                }
            } catch {
                // Ignore body-read errors; the status code is enough.
            }
            throw AIError.httpError(
                statusCode: httpResponse.statusCode,
                message: OpenAICompatibleClient.errorMessage(from: errorText)
            )
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            break
                        }
                        guard let data = payload.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let first = choices.first,
                              let delta = first["delta"] as? [String: Any],
                              let content = delta["content"] as? String,
                              !content.isEmpty else {
                            continue
                        }
                        continuation.yield(content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AIError.networkError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Model list (non-streaming)

    /// Convenience matching the `fetchModels(baseURL:apiKey:)` shape:
    /// GETs `<baseURL>/models` and returns the model ids.
    static func fetchModels(baseURL: String, apiKey: String?) async throws -> [String] {
        try await OpenAICompatibleClient(baseURL: baseURL, apiKey: apiKey).fetchModels()
    }

    func fetchModels() async throws -> [String] {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/models") else {
            throw AIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AIError.httpError(
                statusCode: status,
                message: OpenAICompatibleClient.errorMessage(from: String(data: data, encoding: .utf8) ?? "")
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else {
            throw AIError.invalidResponse
        }

        return items.compactMap { $0["id"] as? String }.sorted()
    }

    // MARK: - Helpers

    /// Pulls a human-readable `message` out of an OpenAI-style error body, if present.
    static func errorMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body.isEmpty ? nil : body
        }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String {
            return message
        }
        return body.isEmpty ? nil : body
    }
}
