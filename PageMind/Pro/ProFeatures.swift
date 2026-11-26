import SwiftUI
import SwiftData

/// Pro feature screens — REAL implementations (Day 8–13 build).
///
/// Every view here is gated on StoreManager.isPro via ProGate
/// (Pro/ProGate.swift). `isPro` stays false until the App Store Connect
/// products exist and a real purchase is made — nothing here fakes a
/// purchase. When Pro is not active, the paywall is shown instead.
///
/// The engines live in their own files:
/// - Browser Agent: Pro/BrowserAgent.swift
/// - Deep Research: Pro/DeepResearch.swift
/// - Morning Brief: Pro/MorningBrief.swift

// MARK: - Browser Agent

/// Approval-gated automation in the in-app browser.
///
/// Flow: type an instruction → the agent plans steps (quick plan first,
/// AI plan if needed) → review the steps, uncheck any you do not want →
/// tap Run. Nothing executes before Run. Stop cancels mid-run. Every
/// step's result is logged below, and the log can be saved as a chat
/// record in the Library.
///
/// The agent acts only in the in-app WKWebView, via the BrowserAgent
/// object owned by BrowserView. It cannot touch Safari or other apps.
struct BrowserAgentView: View {
    @EnvironmentObject private var agent: BrowserAgent
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext

    @State private var instruction = ""
    @State private var plannedSteps: [BrowserAgent.AgentStep] = []
    @State private var approvedStepIDs: Set<UUID> = []
    @State private var didSaveLog = false

    var body: some View {
        ProGate {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Browser Agent")
                        .font(.largeTitle.bold())
                    Text("Ask PageMind to click, type and scroll for you in the in-app browser. Every step waits for your approval first — nothing runs until you tap Run.")
                        .foregroundStyle(.secondary)

                    if agent.webView == nil {
                        Label("Open a page in the Browser tab first — the agent acts on the page that is open there.", systemImage: "globe")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        TextField("e.g. Scroll down, then click Sign in", text: $instruction, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .disabled(agent.isPlanning || agent.isRunning)
                        Button("Plan") {
                            Task { await plan() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || agent.isPlanning || agent.isRunning)
                    }
                    if agent.isPlanning {
                        ProgressView("Planning…")
                    }
                    if let error = agent.planningError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    if !plannedSteps.isEmpty {
                        Text("Steps — check the ones to run")
                            .font(.headline)
                        ForEach(plannedSteps) { step in
                            Toggle(isOn: binding(for: step)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.description)
                                    Text(step.kind.rawValue.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        HStack {
                            Button(agent.isRunning ? "Running…" : "Run approved steps") {
                                agent.run(plannedSteps.filter { approvedStepIDs.contains($0.id) })
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(agent.isRunning || approvedStepIDs.isEmpty)
                            if agent.isRunning {
                                Button("Stop") { agent.stop() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }

                    if !agent.log.isEmpty {
                        Text("Log")
                            .font(.headline)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(agent.log) { entry in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: entry.success ? "checkmark.circle" : "xmark.circle")
                                        .foregroundStyle(entry.success ? .green : .red)
                                    Text(entry.text)
                                        .font(.callout)
                                }
                            }
                        }
                        HStack {
                            Button("Save log to Library") {
                                saveLogAsChat()
                            }
                            Button("Clear log") { agent.clearLog() }
                                .buttonStyle(.bordered)
                        }
                        if didSaveLog {
                            Text("Saved as a chat record in your Library.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("The agent only acts inside PageMind's own browser tab. It never touches Safari or other apps, and it never runs a step you have not approved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Browser Agent")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func binding(for step: BrowserAgent.AgentStep) -> Binding<Bool> {
        Binding(
            get: { approvedStepIDs.contains(step.id) },
            set: { isOn in
                if isOn { approvedStepIDs.insert(step.id) }
                else { approvedStepIDs.remove(step.id) }
            }
        )
    }

    private func plan() async {
        plannedSteps = await agent.plan(instruction: instruction, settings: settings)
        approvedStepIDs = Set(plannedSteps.map(\.id))
    }

    /// Saves the run log as a chat record (a Chat + messages) so it is
    /// visible in the chat history alongside normal conversations.
    private func saveLogAsChat() {
        let chat = Chat(title: "Browser Agent — \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))")
        modelContext.insert(chat)
        let userMessage = ChatMessage(role: "user", content: instruction)
        let logMessage = ChatMessage(role: "assistant", content: agent.logText)
        modelContext.insert(userMessage)
        modelContext.insert(logMessage)
        chat.messages.append(userMessage)
        chat.messages.append(logMessage)
        try? modelContext.save()
        didSaveLog = true
    }
}

// MARK: - Side-by-side compare

/// One prompt, two models, answers side by side.
///
/// Both streams run concurrently. Either side can be picked as the
/// winner, which copies its answer into a new chat so it can be kept
/// or followed up on.
struct CompareView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @StateObject private var catalog = ModelCatalog()

    @State private var question = ""
    @State private var leftModel = ""
    @State private var rightModel = ""
    @State private var leftAnswer = ""
    @State private var rightAnswer = ""
    @State private var leftError: String?
    @State private var rightError: String?
    @State private var isRunning = false
    @State private var winnerSaved: String?

    private var availableModels: [String] {
        let live = catalog.openRouterModels
        if catalog.lastFetchSucceeded, !live.isEmpty {
            return live
        }
        return ModelCatalog.fallbackFreeModels
    }

    var body: some View {
        ProGate {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Compare models")
                        .font(.largeTitle.bold())
                    Text("Run the same question on two models and compare the answers side by side.")
                        .foregroundStyle(.secondary)

                    TextField("Question", text: $question, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Picker("Model A", selection: $leftModel) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        Picker("Model B", selection: $rightModel) {
                            ForEach(availableModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    Button(isRunning ? "Running…" : "Compare") {
                        Task { await runCompare() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || leftModel.isEmpty || rightModel.isEmpty || isRunning)

                    HStack(alignment: .top, spacing: 12) {
                        comparePane(title: "A — \(leftModel)", answer: leftAnswer, error: leftError, isWinner: winnerSaved == "A") {
                            saveWinner("A", answer: leftAnswer)
                        }
                        comparePane(title: "B — \(rightModel)", answer: rightAnswer, error: rightError, isWinner: winnerSaved == "B") {
                            saveWinner("B", answer: rightAnswer)
                        }
                    }
                    if let winnerSaved {
                        Text("Answer \(winnerSaved) saved as a new chat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Both models use your current provider (\(settings.selectedProvider.displayName)). Pick two different models to compare their answers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if leftModel.isEmpty { leftModel = settings.effectiveModel }
                if rightModel.isEmpty { rightModel = ModelCatalog.fallbackFreeModels.last ?? settings.effectiveModel }
                Task { _ = await catalog.fetchOpenRouterModels() }
            }
        }
    }

    private func comparePane(title: String, answer: String, error: String?, isWinner: Bool, onPickWinner: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(2)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if answer.isEmpty {
                Text(isRunning ? "Thinking…" : "Answer will appear here.")
                    .foregroundStyle(.secondary)
            } else {
                Text(answer)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(isWinner ? "Winner ✓" : "Pick winner") {
                onPickWinner()
            }
            .buttonStyle(.bordered)
            .disabled(answer.isEmpty)
        }
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func runCompare() async {
        let prompt = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isRunning = true
        leftAnswer = ""
        rightAnswer = ""
        leftError = nil
        rightError = nil
        winnerSaved = nil
        defer { isRunning = false }

        let config = settings.providerConfig
        let provider = ChatViewModel.provider(for: config, apiKey: settings.apiKey(for: config.kind))
        // Plain tuples (Sendable) — the task-group closures below are
        // @Sendable and cannot capture ChatMessage (@Model, not Sendable).
        let history = [(role: "user", content: prompt)]
        // Hoist the model ids into locals: the @Sendable closures cannot
        // read view properties (that would capture non-Sendable `self`).
        let left = leftModel
        let right = rightModel
        await withTaskGroup(of: (String, Result<String, Error>).self) { group in
            group.addTask {
                do {
                    let text = try await ChatCompletion.collectText(
                        provider: provider, messages: history,
                        model: left, systemPrompt: nil
                    )
                    return ("A", .success(text))
                } catch {
                    return ("A", .failure(error))
                }
            }
            group.addTask {
                do {
                    let text = try await ChatCompletion.collectText(
                        provider: provider, messages: history,
                        model: right, systemPrompt: nil
                    )
                    return ("B", .success(text))
                } catch {
                    return ("B", .failure(error))
                }
            }
            for await (side, result) in group {
                switch result {
                case .success(let text):
                    if side == "A" { leftAnswer = text } else { rightAnswer = text }
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    if side == "A" { leftError = message } else { rightError = message }
                }
            }
        }
    }

    private func saveWinner(_ side: String, answer: String) {
        guard !answer.isEmpty else { return }
        let model = side == "A" ? leftModel : rightModel
        let chat = Chat(title: "Compare winner — \(model)")
        modelContext.insert(chat)
        let userMessage = ChatMessage(role: "user", content: question)
        let answerMessage = ChatMessage(role: "assistant", content: answer)
        modelContext.insert(userMessage)
        modelContext.insert(answerMessage)
        chat.messages.append(userMessage)
        chat.messages.append(answerMessage)
        try? modelContext.save()
        winnerSaved = side
    }
}

// MARK: - Morning Brief

/// Scheduled Morning Brief: a local, on-device summary each morning.
///
/// Scheduling is BGTaskScheduler + a local notification — no server.
/// iOS may delay background tasks, so the screen says so and offers
/// "Generate now", which always works in the foreground.
struct MorningBriefView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @StateObject private var briefSettings = MorningBriefSettings()

    @Query(sort: \SavedPage.savedAt, order: .reverse) private var savedPages: [SavedPage]

    @State private var isGenerating = false
    @State private var statusMessage: String?
    @State private var generatedBrief: String?

    var body: some View {
        ProGate {
            Form {
                Section("Schedule") {
                    Toggle("Morning Brief enabled", isOn: $briefSettings.isEnabled)
                    DatePicker(
                        "Brief time",
                        selection: briefTimeBinding,
                        displayedComponents: .hourAndMinute
                    )
                    TextField("Topics (comma separated)", text: $briefSettings.topics)
                        .textInputAutocapitalization(.never)
                    Toggle("Include recently saved pages", isOn: $briefSettings.includeSavedPages)
                    if let last = briefSettings.lastGenerated {
                        HStack {
                            Text("Last brief")
                            Spacer()
                            Text(last, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Next brief")
                        Spacer()
                        Text(briefSettings.nextFireDate, style: .date)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button(isGenerating ? "Generating…" : "Generate now") {
                        Task { await generateNow() }
                    }
                    .disabled(isGenerating)
                    Button("Save schedule") {
                        saveSchedule()
                    }
                    .disabled(!briefSettings.isEnabled)
                }

                if let statusMessage {
                    Section {
                        Text(statusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let generatedBrief {
                    Section("Latest brief") {
                        Text(generatedBrief)
                            .textSelection(.enabled)
                        Button("Save brief to Library") {
                            saveBriefToLibrary()
                        }
                    }
                }

                Section {
                    Text("Briefs are generated on this device when the background task runs. iOS may delay background tasks (low power, no network, or the app being rarely used), so a brief can arrive late — “Generate now” always works. No server is involved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Morning Brief")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var briefTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: briefSettings.hour,
                    minute: briefSettings.minute,
                    second: 0,
                    of: Date()
                ) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                briefSettings.hour = components.hour ?? 7
                briefSettings.minute = components.minute ?? 0
            }
        )
    }

    private func saveSchedule() {
        Task {
            let allowed = await MorningBriefScheduler.requestNotificationPermission()
            MorningBriefScheduler.scheduleNext()
            statusMessage = allowed
                ? "Scheduled for \(briefSettings.nextFireDate.formatted(date: .abbreviated, time: .shortened)). Notifications are on, so you will be told when it is ready."
                : "Scheduled, but notifications are off — enable them in iOS Settings to be told when the brief is ready."
        }
    }

    private func generateNow() async {
        isGenerating = true
        statusMessage = nil
        defer { isGenerating = false }
        do {
            let brief = try await MorningBriefGenerator.generate(
                settings: settings,
                briefSettings: briefSettings,
                pages: savedPages
            )
            generatedBrief = brief
            briefSettings.lastGeneratedTimestamp = Date().timeIntervalSince1970
            statusMessage = "Brief generated."
        } catch {
            statusMessage = "Could not generate the brief: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func saveBriefToLibrary() {
        guard let generatedBrief else { return }
        let dateString = DateFormatter.localizedString(
            from: Date(), dateStyle: .medium, timeStyle: .none
        )
        let page = SavedPage(
            url: "pagemind://brief/\(Int(Date().timeIntervalSince1970))",
            title: "Morning Brief — \(dateString)",
            readerText: generatedBrief,
            excerpt: ReaderExtractor.excerpt(generatedBrief, maxChars: 300),
            savedAt: Date()
        )
        modelContext.insert(page)
        try? modelContext.save()
        statusMessage = "Saved to your Library."
    }
}

// MARK: - Deep Research

/// Multi-source research: web search → fetch + read the top sources →
/// a structured report with citations, saved to the Library.
struct DeepResearchView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @StateObject private var engine = DeepResearchEngine()

    @State private var topic = ""
    @State private var sourceCount = 5
    @State private var report: DeepResearchEngine.DeepResearchReport?
    @State private var errorMessage: String?
    @State private var didSave = false

    var body: some View {
        ProGate {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Deep Research")
                        .font(.largeTitle.bold())
                    Text("A multi-source research report on any topic, with citations. PageMind searches the web, reads the top sources, and writes the report from those sources only.")
                        .foregroundStyle(.secondary)

                    TextField("Research topic", text: $topic, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    Stepper("Sources: \(sourceCount)", value: $sourceCount, in: 3...10)

                    HStack {
                        Button(engine.isRunning ? "Researching…" : "Run research") {
                            Task { await runResearch() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.isRunning)
                        if engine.isRunning {
                            Button("Stop") { engine.cancel() }
                                .buttonStyle(.bordered)
                        }
                    }
                    if engine.isRunning {
                        HStack {
                            ProgressView()
                            Text(engine.progressText)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }

                    if let report {
                        Text("Report")
                            .font(.headline)
                        if let attributed = try? AttributedString(markdown: report.markdown) {
                            Text(attributed)
                                .textSelection(.enabled)
                        } else {
                            Text(report.markdown)
                                .textSelection(.enabled)
                        }
                        Text("Sources")
                            .font(.headline)
                        ForEach(report.sources) { source in
                            Link(source.title, destination: URL(string: source.url) ?? URL(string: "https://example.com")!)
                                .font(.callout)
                        }
                        Button(didSave ? "Saved ✓" : "Save report to Library") {
                            saveReport()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(didSave)
                    }
                }
                .padding()
            }
            .navigationTitle("Deep Research")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func runResearch() async {
        errorMessage = nil
        report = nil
        didSave = false
        do {
            report = try await engine.research(
                topic: topic,
                sourceCount: sourceCount,
                settings: settings
            )
        } catch is CancellationError {
            errorMessage = "Research stopped."
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func saveReport() {
        guard let report else { return }
        let page = SavedPage(
            url: "pagemind://research/\(UUID().uuidString)",
            title: "Research: \(report.topic)",
            readerText: report.markdown,
            excerpt: ReaderExtractor.excerpt(report.markdown, maxChars: 300),
            savedAt: Date()
        )
        modelContext.insert(page)
        try? modelContext.save()
        didSave = true
    }
}
