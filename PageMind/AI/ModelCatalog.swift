import Foundation

/// Fetches the live OpenRouter model list and falls back to a small
/// curated list of free models when the network is unavailable.
@MainActor
final class ModelCatalog: ObservableObject {
    static let defaultModel = "openrouter/free"

    /// Free models change often — the live list from OpenRouter always wins
    /// over this fallback when it can be fetched.
    static let fallbackFreeModels: [String] = [
        "openrouter/free",
        "nvidia/nemotron-3-nano-30b-a3b:free",
        "meta-llama/llama-3.3-70b-instruct:free",
        "google/gemma-3-27b-it:free",
    ]

    @Published private(set) var openRouterModels: [String] = fallbackFreeModels
    @Published private(set) var lastFetchSucceeded = false

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetches model ids from https://openrouter.ai/api/v1/models.
    /// No API key is required for this list. Returns the fallback list
    /// (and records the failure) when the fetch fails for any reason.
    func fetchOpenRouterModels(apiKey: String? = nil) async -> [String] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else {
            lastFetchSucceeded = false
            return Self.fallbackFreeModels
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["data"] as? [[String: Any]] else {
                lastFetchSucceeded = false
                return Self.fallbackFreeModels
            }
            let models = items.compactMap { $0["id"] as? String }.sorted()
            guard !models.isEmpty else {
                lastFetchSucceeded = false
                return Self.fallbackFreeModels
            }
            openRouterModels = models
            lastFetchSucceeded = true
            return models
        } catch {
            lastFetchSucceeded = false
            return Self.fallbackFreeModels
        }
    }

    /// Free models only, from the last fetched (or fallback) list.
    var freeModels: [String] {
        let free = openRouterModels.filter { $0.contains(":free") || $0 == "openrouter/free" }
        return free.isEmpty ? Self.fallbackFreeModels : free
    }
}
