import Foundation

// MARK: - Provider kinds

enum AIProviderKind: String, CaseIterable, Identifiable, Codable {
    case openRouter
    case openAI
    case anthropic
    case gemini
    case groq
    case ollama
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openRouter: return "OpenRouter"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .groq: return "Groq"
        case .ollama: return "Ollama (local)"
        case .custom: return "Custom (OpenAI-compatible)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .groq: return "https://api.groq.com/openai/v1"
        case .ollama: return "http://localhost:11434/v1"
        case .custom: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .openRouter: return "openrouter/free"
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-sonnet-4-5"
        case .gemini: return "gemini-2.5-flash"
        case .groq: return "llama-3.3-70b-versatile"
        case .ollama: return "llama3.2"
        case .custom: return ""
        }
    }

    /// Whether this kind needs an API key stored in the Keychain.
    var requiresKey: Bool {
        switch self {
        case .ollama: return false
        default: return true
        }
    }
}

// MARK: - Errors

enum AIError: LocalizedError {
    case missingAPIKey
    case invalidURL
    case httpError(statusCode: Int, message: String?)
    case invalidResponse
    case networkError(Error)
    case streamEndedUnexpectedly
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key saved for this provider. Add one in Settings."
        case .invalidURL:
            return "The provider URL is invalid. Check the base URL in Settings."
        case .httpError(let statusCode, let message):
            if let message, !message.isEmpty {
                return "Provider error (\(statusCode)): \(message)"
            }
            return "Provider error (HTTP \(statusCode))."
        case .invalidResponse:
            return "The provider returned a response PageMind could not understand."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .streamEndedUnexpectedly:
            return "The response stream ended unexpectedly."
        case .unsupportedProvider:
            return "This provider is not supported yet."
        }
    }
}

// MARK: - Configuration (key itself lives in the Keychain, never here)

struct ProviderConfig: Codable, Hashable {
    var kind: AIProviderKind
    var baseURL: String
    /// Keychain item identifier for the API key — never the key itself.
    var apiKeyID: String?
    var model: String

    init(
        kind: AIProviderKind,
        baseURL: String? = nil,
        apiKeyID: String? = nil,
        model: String? = nil
    ) {
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.apiKeyID = apiKeyID
        self.model = model ?? kind.defaultModel
    }
}

// MARK: - Provider protocol

protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var defaultBaseURL: String { get }
    var requiresKey: Bool { get }
    var defaultModel: String { get }

    /// Whether this provider can take images (JPEG data) as vision input.
    /// Defaults to false; vision-capable providers override it.
    /// Note: the *model* must also support vision — a text-only model will
    /// return a provider error, which surfaces as a chat error.
    var supportsVision: Bool { get }

    /// Streams the assistant's reply as text tokens.
    /// - Parameters:
    ///   - messages: Full conversation history (role/content).
    ///   - model: Model identifier to request.
    ///   - systemPrompt: Optional system prompt; nil means no system message.
    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?
    ) -> AsyncThrowingStream<String, Error>

    /// Same as `streamChat`, with JPEG image data attached to the last user
    /// message as vision input. The default implementation ignores the
    /// images and streams text-only (for providers without vision support).
    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?,
        images: [Data]
    ) -> AsyncThrowingStream<String, Error>
}

extension AIProvider {
    var supportsVision: Bool { false }

    func streamChat(
        messages: [ChatMessage],
        model: String,
        systemPrompt: String?,
        images: [Data]
    ) -> AsyncThrowingStream<String, Error> {
        streamChat(messages: messages, model: model, systemPrompt: systemPrompt)
    }
}
