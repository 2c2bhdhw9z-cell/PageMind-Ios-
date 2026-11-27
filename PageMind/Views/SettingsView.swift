import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The pages inside Settings.
enum SettingsPage: Hashable {
    case models
    case apiKeys
    case systemPrompt
    case skills
    case webSearch
    case localServers
    case morningBrief
    case importExport
    case privacy
}

/// Settings, laid out like SurfMind's (owner's screenshots, 26 Nov
/// 2026): a full-height sheet with a close button, the app and plan at
/// the top, an Upgrade banner, then short rows grouped under small
/// headings. Each row opens its own page, so the main list stays short.
///
/// PageMind has no account and no credits, so there are no account
/// rows. Keys are never displayed: each field shows "Saved" or
/// "Not set" and only writes to the Keychain when a new value is saved.
struct SettingsView: View {
    // The single app-level settings instance, injected by PageMindApp.
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = StoreManager.shared
    @StateObject private var catalog = ModelCatalog()
    @StateObject private var briefSettings = MorningBriefSettings()

    @State private var path: [SettingsPage]

    @State private var openRouterKey = ""
    @State private var openAIKey = ""
    @State private var anthropicKey = ""
    @State private var geminiKey = ""
    @State private var groqKey = ""
    @State private var braveKey = ""
    /// Bumped after a key is saved or cleared so "Saved" / "Not set"
    /// re-reads the Keychain.
    @State private var keyRefresh = 0
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

    /// `startPage` opens Settings straight on one page (the chat's
    /// "Add a free AI key" button opens API keys).
    init(startPage: SettingsPage? = nil) {
        _path = State(initialValue: startPage.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                headerSection

                if !store.isPro {
                    upgradeSection
                }

                Section("AI") {
                    navRow("Models", systemImage: "cpu", value: settings.selectedProvider.displayName, page: .models)
                    navRow("API keys", systemImage: "key", value: savedKeysText, page: .apiKeys)
                    navRow("System prompt", systemImage: "text.bubble", value: nil, page: .systemPrompt)
                    navRow("Skills", systemImage: "wand.and.stars", value: settings.activeSkillPreset?.name, page: .skills)
                    navRow("Web search", systemImage: "globe", value: settings.hasBraveKey ? "Brave" : "Free", page: .webSearch)
                    navRow("Local & custom servers", systemImage: "server.rack", value: nil, page: .localServers)
                }
                .listRowBackground(PageMindDesign.elevatedCard)

                Section {
                    Picker(selection: $settings.appThemeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.label).tag(theme.rawValue)
                        }
                    } label: {
                        rowLabel("Theme", systemImage: "circle.lefthalf.filled")
                    }
                    Picker(selection: $settings.appLanguageRaw) {
                        ForEach(AppLanguage.choices, id: \.code) { language in
                            Text(language.label).tag(language.code)
                        }
                    } label: {
                        rowLabel("Display language", systemImage: "character.bubble")
                    }
                    Picker(selection: $settings.appFontSizeRaw) {
                        ForEach(AppFontSize.allCases) { size in
                            Text(size.label).tag(size.rawValue)
                        }
                    } label: {
                        rowLabel("Font size", systemImage: "textformat.size")
                    }
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("Display language changes how dates and numbers are shown. PageMind's own text is in English.")
                }
                .listRowBackground(PageMindDesign.elevatedCard)

                Section("Features") {
                    navRow("Morning Brief", systemImage: "sunrise", value: briefSettings.isEnabled ? "On" : "Off", page: .morningBrief)
                }
                .listRowBackground(PageMindDesign.elevatedCard)

                Section("Data") {
                    navRow("Import and export", systemImage: "arrow.up.arrow.down", value: nil, page: .importExport)
                }
                .listRowBackground(PageMindDesign.elevatedCard)

                Section {
                    navRow("Privacy", systemImage: "hand.raised", value: nil, page: .privacy)
                    HStack {
                        rowLabel("Version", systemImage: "info.circle")
                        Spacer()
                        Text(versionText)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(PageMindDesign.elevatedCard)
            }
            .settingsListStyle()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: SettingsPage.self) { page in
                destination(for: page)
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
            exportSheet
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

    // MARK: - Main list pieces

    private var headerSection: some View {
        Section {
            VStack(spacing: 8) {
                BrandMark(size: 60)
                Text("PageMind")
                    .font(.title3.weight(.semibold))
                Text(store.isPro ? "Pro plan" : "Free plan")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .listRowBackground(Color.clear)
        }
    }

    private var upgradeSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(PageMindDesign.brandCyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Upgrade to PageMind Pro")
                        .font(.subheadline.weight(.semibold))
                    Text("Browser Agent, Deep Research, Compare and Morning Brief.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Upgrade") {
                    showingPaywall = true
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(PageMindDesign.brandGradient)
                .clipShape(Capsule())
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(PageMindDesign.brandIndigo.opacity(0.16))
    }

    private func navRow(_ title: String, systemImage: String, value: String?, page: SettingsPage) -> some View {
        NavigationLink(value: page) {
            HStack {
                rowLabel(title, systemImage: systemImage)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func rowLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
                .foregroundStyle(PageMindDesign.primaryText)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }

    private var savedKeysText: String {
        _ = keyRefresh
        let ids = [KeychainStore.openRouter, KeychainStore.openAI, KeychainStore.anthropic, KeychainStore.gemini, KeychainStore.groq]
        let count = ids.filter { KeychainStore.hasKey($0) }.count
        return count == 0 ? "None" : "\(count) saved"
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Pages

    @ViewBuilder
    private func destination(for page: SettingsPage) -> some View {
        switch page {
        case .models: modelsPage
        case .apiKeys: apiKeysPage
        case .systemPrompt: systemPromptPage
        case .skills: skillsPage
        case .webSearch: webSearchPage
        case .localServers: localServersPage
        case .morningBrief: morningBriefPage
        case .importExport: importExportPage
        case .privacy: privacyPage
        }
    }

    private var modelsPage: some View {
        List {
            Section {
                Picker("Provider", selection: $settings.selectedProviderRaw) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                TextField("Model", text: $settings.selectedModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("You can also change the model from the chip above the message box.")
            }
            .listRowBackground(PageMindDesign.elevatedCard)

            Section {
                Button("Fetch OpenRouter models") {
                    Task { await fetchOpenRouterModels() }
                }
                .foregroundStyle(PageMindDesign.brandIndigo)
                .disabled(isFetchingModels)
                if isFetchingModels {
                    ProgressView()
                }
                if let fetchError {
                    Text(fetchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !fetchedModels.isEmpty {
                    Picker("OpenRouter model", selection: $settings.selectedModel) {
                        ForEach(fetchedModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var apiKeysPage: some View {
        List {
            Section {
                Text("OpenRouter has free AI models. Make a free account, create a key, then paste it into the OpenRouter box below and tap Save.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = URL(string: "https://openrouter.ai/keys") {
                    Link(destination: url) {
                        Label("Get a free OpenRouter key", systemImage: "arrow.up.right.square")
                            .foregroundStyle(PageMindDesign.brandIndigo)
                    }
                }
            } header: {
                Text("Start free")
            }
            .listRowBackground(PageMindDesign.elevatedCard)

            Section {
                keyField(label: "OpenRouter", keyID: KeychainStore.openRouter, text: $openRouterKey)
                keyField(label: "OpenAI", keyID: KeychainStore.openAI, text: $openAIKey)
                keyField(label: "Anthropic", keyID: KeychainStore.anthropic, text: $anthropicKey)
                keyField(label: "Gemini", keyID: KeychainStore.gemini, text: $geminiKey)
                keyField(label: "Groq", keyID: KeychainStore.groq, text: $groqKey)
            } header: {
                Text("Your keys")
            } footer: {
                Text("Keys are stored in the iOS Keychain on this device and are never shown again.")
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("API keys")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var systemPromptPage: some View {
        List {
            Section {
                TextEditor(text: $settings.systemPrompt)
                    .frame(minHeight: 220)
            } footer: {
                Text("Instructions sent at the start of every chat. Picking a skill replaces this text.")
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("System prompt")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var skillsPage: some View {
        List {
            Section {
                ForEach(SkillPreset.builtIns) { preset in
                    skillRow(preset)
                }
                ForEach(settings.customSkillPresets) { preset in
                    skillRow(preset)
                }
            } footer: {
                Text("A skill is a saved system prompt. Tap one to use it for new chats. Swipe left on your own skills to delete them.")
            }
            .listRowBackground(PageMindDesign.elevatedCard)

            Section {
                Button {
                    newSkillName = ""
                    newSkillPrompt = ""
                    showingNewSkill = true
                } label: {
                    Label("New skill", systemImage: "plus")
                        .foregroundStyle(PageMindDesign.brandIndigo)
                }
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var webSearchPage: some View {
        List {
            Section {
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
            } footer: {
                Text("Web search works without a key. A Brave Search key is optional and can give better results.")
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("Web search")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var localServersPage: some View {
        List {
            Section {
                TextField("Ollama base URL", text: $settings.ollamaBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("Ollama")
            }
            .listRowBackground(PageMindDesign.elevatedCard)

            Section {
                TextField("Custom base URL", text: $settings.customBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Custom model", text: $settings.customModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Custom (OpenAI-compatible)")
            } footer: {
                Text("For AI running on your own computer or server. Pick Ollama or Custom as the provider under Models to use it.")
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("Local & custom servers")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var morningBriefPage: some View {
        List {
            Section {
                Toggle("Morning Brief", isOn: $briefSettings.isEnabled)
                Toggle("Notify me when it's ready", isOn: $briefSettings.notificationsEnabled)
                    .disabled(!briefSettings.isEnabled)
            } footer: {
                Text("The Morning Brief is made on this phone and saved to your Library. iOS decides the exact time it runs, so it can be late. Open Morning Brief from the menu to make one now.")
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("Morning Brief")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var importExportPage: some View {
        List {
            Section {
                Button {
                    exportURL = makeBackupURL()
                    if exportURL != nil {
                        showingExportSheet = true
                    }
                } label: {
                    Label("Export settings and chats", systemImage: "square.and.arrow.up")
                        .foregroundStyle(PageMindDesign.brandIndigo)
                }
                Button {
                    showingImport = true
                } label: {
                    Label("Import settings and chats", systemImage: "square.and.arrow.down")
                        .foregroundStyle(PageMindDesign.brandIndigo)
                }
                if let importStatus {
                    Text(importStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("The backup is one file with your settings and chats. API keys are never included.")
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("Import and export")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var privacyPage: some View {
        List {
            Section {
                Text("Pages you save and the text you ask about stay on this device. API keys are stored in the iOS Keychain. PageMind does not run its own server and does not sell or share your data. Questions you ask go to the AI provider you picked, under that provider's privacy policy.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .listRowBackground(PageMindDesign.elevatedCard)
        }
        .settingsListStyle()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sheets

    @ViewBuilder
    private var exportSheet: some View {
        if let exportURL {
            NavigationStack {
                VStack(spacing: 16) {
                    Text("Your settings and chats are saved as a single file. Share it to keep a copy, or import it on another device running PageMind.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding()
                    ShareLink("Share backup", item: exportURL)
                        .buttonStyle(.borderedProminent)
                        .tint(PageMindDesign.brandIndigo)
                        .controlSize(.large)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .background(PageMindDesign.appBackground)
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
                        .foregroundStyle(PageMindDesign.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(preset.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if settings.activeSkillPreset?.id == preset.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(PageMindDesign.brandIndigo)
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
        let isSaved: Bool = {
            _ = keyRefresh
            return KeychainStore.hasKey(keyID)
        }()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(isSaved ? "Saved" : "Not set")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSaved ? Color.green : Color.secondary)
            }
            SecureField(isSaved ? "Paste a new key to replace it" : "Paste your \(label) key", text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(PageMindDesign.subtleCard)
                )
            HStack(spacing: 16) {
                Button("Save") {
                    guard !text.wrappedValue.isEmpty else { return }
                    KeychainStore.save(key: keyID, value: text.wrappedValue)
                    text.wrappedValue = ""
                    keyRefresh += 1
                }
                .disabled(text.wrappedValue.isEmpty)
                .foregroundStyle(text.wrappedValue.isEmpty ? Color.secondary : PageMindDesign.brandIndigo)
                Button("Clear") {
                    KeychainStore.delete(key: keyID)
                    keyRefresh += 1
                }
                .disabled(!isSaved)
                .foregroundStyle(isSaved ? Color.red : Color.secondary)
                Spacer()
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }

    private func fetchOpenRouterModels() async {
        isFetchingModels = true
        fetchError = nil
        defer { isFetchingModels = false }
        // ModelCatalog is a @MainActor ObservableObject with no shared
        // singleton; fetchOpenRouterModels() is non-throwing and returns
        // the fallback list on failure.
        fetchedModels = await catalog.fetchOpenRouterModels()
        if !catalog.lastFetchSucceeded {
            fetchError = "Could not reach OpenRouter — showing the fallback free-model list."
        } else if fetchedModels.isEmpty {
            fetchError = "No models returned."
        }
    }
}

private extension View {
    /// Settings lists sit on the app's charcoal background, not the
    /// system's near-black, so the cards read as cards.
    func settingsListStyle() -> some View {
        self
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(PageMindDesign.appBackground)
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
