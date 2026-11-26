import SwiftUI

/// Settings: provider, API keys (Keychain), model, system prompt,
/// Brave Search, Ollama / custom endpoints, paywall and privacy.
///
/// Keys are never displayed: each field shows "Saved" or "Not set" and
/// only writes to the Keychain when the user enters a new value.
struct SettingsView: View {
    // The single app-level settings instance, injected by PageMindApp.
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var store = StoreManager.shared
    @StateObject private var catalog = ModelCatalog()

    @State private var openRouterKey = ""
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var groqKey = ""
    @State private var braveKey = ""
    @State private var fetchedModels: [String] = []
    @State private var isFetchingModels = false
    @State private var fetchError: String?
    @State private var showingPaywall = false

    var body: some View {
        NavigationStack {
            Form {
                Section("AI Provider") {
                    Picker("Provider", selection: $settings.selectedProviderRaw) {
                        ForEach(AIProviderKind.allCases) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                    TextField("Model", text: $settings.selectedModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Fetch OpenRouter models") {
                        Task { await fetchOpenRouterModels() }
                    }
                    .disabled(isFetchingModels)
                    if isFetchingModels {
                        ProgressView()
                    }
                    if let fetchError {
                        Text(fetchError).foregroundStyle(.red).font(.caption)
                    }
                    if !fetchedModels.isEmpty {
                        Picker("OpenRouter model", selection: $settings.selectedModel) {
                            ForEach(fetchedModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                }

                Section("API Keys") {
                    Text("Keys are stored in the iOS Keychain on this device and are never shown again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    keyField(label: "OpenRouter", keyID: KeychainStore.openRouter, text: $openRouterKey)
                    keyField(label: "OpenAI", keyID: KeychainStore.openAI, text: $openAIKey)
                    keyField(label: "Anthropic", keyID: KeychainStore.anthropic, text: $anthropicKey)
                    keyField(label: "Gemini", keyID: KeychainStore.gemini, text: $geminiKey)
                    keyField(label: "Groq", keyID: KeychainStore.groq, text: $groqKey)
                }

                Section("System Prompt") {
                    TextEditor(text: $settings.systemPrompt)
                        .frame(minHeight: 100)
                }

                Section("Web Search (optional)") {
                    SecureField("Brave Search API key", text: $braveKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(settings.hasBraveKey ? "Saved" : "Not set")
                            .foregroundStyle(.secondary)
                    }
                    Button("Save Brave key") {
                        guard !braveKey.isEmpty else { return }
                        KeychainStore.save(key: KeychainStore.brave, value: braveKey)
                        settings.braveAPIKeyID = true
                        braveKey = ""
                    }
                    .disabled(braveKey.isEmpty)
                }

                Section("Local / Custom") {
                    TextField("Ollama base URL", text: $settings.ollamaBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Custom base URL", text: $settings.customBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Custom model", text: $settings.customModel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("PageMind Pro") {
                    Button(store.isPro ? "Pro active" : "Get PageMind Pro") {
                        showingPaywall = true
                    }
                    .disabled(store.isPro)
                }

                Section("Privacy") {
                    Text("Pages you save and the text you ask about stay on this device. API keys are stored in the iOS Keychain. PageMind does not run its own server and does not sell or share your data. Requests you make go to the AI provider you selected, under that provider's privacy policy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("PageMind 1.0 (Day 1-2 build)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: settings.selectedProviderRaw) { _, newValue in
                // Changing provider resets the model to that provider's
                // default — the old model id belongs to the old provider
                // and would otherwise be sent to the wrong API.
                if let kind = AIProviderKind(rawValue: newValue) {
                    settings.selectedModel = kind.defaultModel
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .task {
                await store.loadProducts()
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func keyField(label: String, keyID: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("\(label) API key", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Text("Status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(KeychainStore.hasKey(keyID) ? "Saved" : "Not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Save") {
                    guard !text.wrappedValue.isEmpty else { return }
                    KeychainStore.save(key: keyID, value: text.wrappedValue)
                    text.wrappedValue = ""
                }
                .disabled(text.wrappedValue.isEmpty)
                Button("Clear") {
                    KeychainStore.delete(key: keyID)
                }
                .disabled(!KeychainStore.hasKey(keyID))
            }
        }
    }

    private func fetchOpenRouterModels() async {
        isFetchingModels = true
        fetchError = nil
        defer { isFetchingModels = false }
        // ModelCatalog (other builder) is a @MainActor ObservableObject with
        // no shared singleton: `ModelCatalog().fetchOpenRouterModels() async -> [String]`
        // (non-throwing — it returns the fallback list on failure).
        fetchedModels = await catalog.fetchOpenRouterModels()
        if !catalog.lastFetchSucceeded {
            fetchError = "Could not reach OpenRouter — showing the fallback free-model list."
        } else if fetchedModels.isEmpty {
            fetchError = "No models returned."
        }
    }
}
