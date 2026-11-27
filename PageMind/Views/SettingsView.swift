import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings, organised the way SurfMind's settings are — General first
/// (Pro status, import/export, API keys, appearance, Morning Brief
/// notifications), then Models, System prompt, and Skills — but with
/// PageMind's own features: no account, no credits, no MCP rows (PageMind
/// has no MCP runtime; a fake row would be a dead button).
///
/// Keys are never displayed: each field shows "Saved" or "Not set" and
/// only writes to the Keychain when the user enters a new value.
struct SettingsView: View {
    // The single app-level settings instance, injected by PageMindApp.
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @StateObject private var store = StoreManager.shared
    @StateObject private var catalog = ModelCatalog()
    @StateObject private var briefSettings = MorningBriefSettings()

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

    @State private var exportURL: URL?
    @State private var showingExportSheet = false
    @State private var showingImport = false
    @State private var importStatus: String?

    @State private var showingNewSkill = false
    @State private var newSkillName = ""
    @State private var newSkillPrompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    HStack {
                        Text("PageMind Pro")
                        Spacer()
                        Button(store.isPro ? "Pro active" : "Get Pro") {
                            showingPaywall = true
                        }
                        .disabled(store.isPro)
                    }

                    Button("Export settings and chats") {
                        exportURL = makeBackupURL()
                        if exportURL != nil {
                            showingExportSheet = true
                        }
                    }
                    Button("Import settings and chats") {
                        showingImport = true
                    }
                    if let importStatus {
                        Text(importStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Picker("Theme", selection: $settings.appThemeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    }
                    Picker("Font size", selection: $settings.appFontSizeRaw) {
                        ForEach(AppFontSize.allCases) { size in
                            Text(size.label).tag(size.rawValue)
                        }
                    }
                    Picker("Display language", selection: $settings.appLanguageRaw) {
                        ForEach(AppLanguage.choices, id: \.code) { language in
                            Text(language.label).tag(language.code)
                        }
                    }
                    Text("Display language changes dates and numbers shown by the system. PageMind's own text is English only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("Morning Brief", isOn: $briefSettings.isEnabled)
                    Toggle("Brief notifications", isOn: $briefSettings.notificationsEnabled)
                        .disabled(!briefSettings.isEnabled)
                    Text("The Morning Brief is generated on this device and saved to your Library. Notifications only tell you when a new brief is ready.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                Section("Models") {
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

                Section("System Prompt") {
                    TextEditor(text: $settings.systemPrompt)
                        .frame(minHeight: 100)
                }

                Section("Skills") {
                    Text("Skills are saved system prompts. Tap one to make it the active system prompt for new chats.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(SkillPreset.builtIns) { preset in
                        skillRow(preset)
                    }
                    if !settings.customSkillPresets.isEmpty {
                        ForEach(settings.customSkillPresets) { preset in
                            skillRow(preset)
                        }
                    }
                    Button("New skill") {
                        newSkillName = ""
                        newSkillPrompt = ""
                        showingNewSkill = true
                    }
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
            .safeAreaPadding(.bottom, 16)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    SidebarToggleButton()
                }
            }
            .onChange(of: settings.selectedProviderRaw) { _, newValue in
                // Changing provider resets the model to that provider's
                // default — the old model id belongs to the old provider
                // and would otherwise be sent to the wrong API.
                if let kind = AIProviderKind(rawValue: newValue) {
                    settings.selectedModel = kind.defaultModel
                }
            }
            .onChange(of: briefSettings.isEnabled) { _, enabled in
                // The Morning Brief schedule lives or dies with this
                // toggle: enable schedules the next run, disable cancels
                // anything pending.
                if enabled {
                    MorningBriefScheduler.scheduleNext()
                } else {
                    MorningBriefScheduler.cancelPending()
                }
            }
            .onChange(of: briefSettings.notificationsEnabled) { _, enabled in
                if enabled {
                    Task {
                        _ = await MorningBriefScheduler.requestNotificationPermission()
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showingExportSheet) {
                if let exportURL {
                    NavigationStack {
                        VStack(spacing: 16) {
                            Text("Your settings and chats are saved as a single JSON file. Share it to keep a copy, or import it on another device running PageMind.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding()
                            ShareLink("Share backup", item: exportURL)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            Spacer()
                        }
                        .navigationTitle("Export backup")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingExportSheet = false }
                            }
                        }
                    }
                    .presentationDetents([.medium])
                }
            }
            .sheet(isPresented: $showingNewSkill) {
                newSkillSheet
            }
            .fileImporter(
                isPresented: $showingImport,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                importBackup(result)
            }
            .task {
                await store.loadProducts()
            }
        }
    }

    // MARK: - Skills

    /// One skill row: tap to make it the active system prompt. The
    /// active one shows a checkmark. Custom skills can be deleted with
    /// swipe-to-delete; built-ins cannot.
    private func skillRow(_ preset: SkillPreset) -> some View {
        Button {
            settings.systemPrompt = preset.prompt
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(preset.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if settings.activeSkillPreset?.id == preset.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .swipeActions {
            if !preset.isBuiltIn {
                Button(role: .destructive) {
                    settings.customSkillPresets.removeAll { $0.id == preset.id }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var newSkillSheet: some View {
        NavigationStack {
            Form {
                TextField("Skill name", text: $newSkillName)
                TextEditor(text: $newSkillPrompt)
                    .frame(minHeight: 160)
                Text("A skill is a saved system prompt. Tapping it in Settings makes it the prompt for new chats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("New skill")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingNewSkill = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let name = newSkillName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let prompt = newSkillPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !prompt.isEmpty else { return }
                        settings.customSkillPresets.append(
                            SkillPreset(name: name, prompt: prompt)
                        )
                        showingNewSkill = false
                    }
                    .disabled(
                        newSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || newSkillPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Import / export

    /// Builds the backup JSON (settings + all chats with messages) and
    /// writes it to a temp file. Returns nil when nothing could be read.
    private func makeBackupURL() -> URL? {
        let chats = (try? modelContext.fetch(
            FetchDescriptor<Chat>(sortBy: [SortDescriptor(\.createdAt)])
        )) ?? []
        let backup = PageMindBackup(
            version: 1,
            exportedAt: Date(),
            providerRaw: settings.selectedProviderRaw,
            model: settings.selectedModel,
            systemPrompt: settings.systemPrompt,
            themeRaw: settings.appThemeRaw,
            fontSizeRaw: settings.appFontSizeRaw,
            languageRaw: settings.appLanguageRaw,
            chats: chats.map { chat in
                PageMindBackup.BackedUpChat(
                    title: chat.title,
                    createdAt: chat.createdAt,
                    messages: chat.messages
                        .sorted { $0.createdAt < $1.createdAt }
                        .map {
                            PageMindBackup.BackedUpMessage(
                                role: $0.role,
                                content: $0.content,
                                createdAt: $0.createdAt,
                                citationsJSON: $0.citationsJSON
                            )
                        }
                )
            }
        )
        guard let data = try? JSONEncoder().encode(backup) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageMind-backup.json")
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    /// Reads a backup file produced by Export, applies its settings and
    /// restores its chats (with messages) into the library. Imported
    /// chats are new records — existing chats are never overwritten.
    private func importBackup(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first,
              url.startAccessingSecurityScopedResource() else {
            importStatus = "Could not open the backup file."
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url),
              let backup = try? JSONDecoder().decode(PageMindBackup.self, from: data),
              backup.version == 1 else {
            importStatus = "That file is not a PageMind backup."
            return
        }

        settings.selectedProviderRaw = backup.providerRaw
        settings.selectedModel = backup.model
        settings.systemPrompt = backup.systemPrompt
        settings.appThemeRaw = backup.themeRaw
        settings.appFontSizeRaw = backup.fontSizeRaw
        settings.appLanguageRaw = backup.languageRaw

        var importedChats = 0
        for backedUpChat in backup.chats {
            let chat = Chat(title: backedUpChat.title, createdAt: backedUpChat.createdAt)
            modelContext.insert(chat)
            for backedUpMessage in backedUpChat.messages {
                let message = ChatMessage(
                    role: backedUpMessage.role,
                    content: backedUpMessage.content,
                    createdAt: backedUpMessage.createdAt,
                    citationsJSON: backedUpMessage.citationsJSON
                )
                chat.messages.append(message)
                modelContext.insert(message)
            }
            importedChats += 1
        }
        do {
            try modelContext.save()
            importStatus = "Imported \(importedChats) chat\(importedChats == 1 ? "" : "s") and restored your settings."
        } catch {
            importStatus = "Imported the chats, but the save failed: \(error.localizedDescription)"
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

// MARK: - Backup format

/// The JSON backup produced by Settings → Export and read by Import.
/// Versioned so a future format change can be detected and rejected
/// instead of half-applied. API keys are never included — they stay in
/// the Keychain and must be re-entered after an import.
private struct PageMindBackup: Codable {
    var version: Int
    var exportedAt: Date
    var providerRaw: String
    var model: String
    var systemPrompt: String
    var themeRaw: String
    var fontSizeRaw: String
    var languageRaw: String
    var chats: [BackedUpChat]

    struct BackedUpChat: Codable {
        var title: String
        var createdAt: Date
        var messages: [BackedUpMessage]
    }

    struct BackedUpMessage: Codable {
        var role: String
        var content: String
        var createdAt: Date
        var citationsJSON: String
    }
}
