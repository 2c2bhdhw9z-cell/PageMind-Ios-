import Foundation
import WebKit

/// Browser Agent engine: plans and runs click / type / scroll / navigate
/// steps in the in-app WKWebView — and nowhere else.
///
/// Approval model (this is the whole point): planning produces a list of
/// steps, the user reviews them in BrowserAgentView, checks the ones
/// they want, and only then taps Run. Nothing executes before that tap.
/// A Stop button cancels the run mid-step. Every step's result is
/// appended to `log`.
///
/// Planning is two-stage: an AI planner (the user's own provider) turns
/// a plain-language instruction + a snapshot of the page's clickable
/// elements into JSON steps; if that fails, a rule-based planner handles
/// the common instructions ("scroll down", "click Sign in", "go back").
@MainActor
final class BrowserAgent: ObservableObject {
    /// The web view the agent acts in. Set by BrowserView; weak so the
    /// agent never keeps the browser alive.
    weak var webView: WKWebView?

    @Published private(set) var isRunning = false
    @Published private(set) var isPlanning = false
    @Published private(set) var log: [AgentLogEntry] = []
    @Published var planningError: String?

    private var runTask: Task<Void, Never>?

    // MARK: - Steps

    enum StepKind: String, Codable {
        case click
        case type
        case scroll
        case navigate
        case back
        case reload
    }

    struct AgentStep: Identifiable, Codable, Hashable {
        var id: UUID = UUID()
        var kind: StepKind
        /// Human-readable description shown in the approval list.
        var description: String
        /// For click: the link/button text to match. For type: the text to
        /// type. For navigate: the URL. For scroll: "down" / "up" / "top".
        var target: String
        /// For type: a hint identifying the field (placeholder, label or
        /// name). Empty for other kinds.
        var fieldHint: String = ""
    }

    // MARK: - Planning

    /// Plans steps for an instruction on the current page.
    /// Returns the steps (possibly empty) and records a log line.
    func plan(instruction: String, settings: AppSettings) async -> [AgentStep] {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        isPlanning = true
        planningError = nil
        defer { isPlanning = false }

        let snapshot = await pageSnapshot()
        // Rule-based first: it is instant, free, and covers the common
        // instructions without spending a model call.
        if let steps = ruleBasedPlan(instruction: trimmed), !steps.isEmpty {
            log.append(AgentLogEntry(text: "Planned \(steps.count) step(s) for “\(trimmed)” (quick plan).", success: true))
            return steps
        }
        // AI planner: the model sees the page snapshot and returns JSON.
        do {
            let planText = try await ChatCompletion.ask(
                settings: settings,
                prompt: """
                You are planning browser actions for a user. Page snapshot:
                \(snapshot)

                User instruction: \(trimmed)

                Reply with ONLY a JSON array of steps, no other text. Each step:
                {"kind": "click"|"type"|"scroll"|"navigate"|"back"|"reload", "description": "plain words", "target": "text to click, text to type, URL, or down/up/top", "fieldHint": "placeholder or label for type steps, else empty"}
                At most 8 steps. Use only elements that appear in the snapshot. If the instruction cannot be done on this page, reply with [].
                """,
                systemPrompt: "You plan browser automation steps. Reply with JSON only."
            )
            let steps = parsePlanJSON(planText)
            if steps.isEmpty {
                planningError = "I could not plan that on this page. Try rephrasing it, or use a quick action like “scroll down”."
                log.append(AgentLogEntry(text: "Could not plan “\(trimmed)” on this page.", success: false))
            } else {
                log.append(AgentLogEntry(text: "Planned \(steps.count) step(s) for “\(trimmed)”.", success: true))
            }
            return steps
        } catch {
            planningError = "Planning failed: \(error.localizedDescription). Try a quick action instead."
            log.append(AgentLogEntry(text: "Planning failed: \(error.localizedDescription)", success: false))
            return ruleBasedPlan(instruction: trimmed) ?? []
        }
    }

    /// Quick plans that need no model call.
    func ruleBasedPlan(instruction: String) -> [AgentStep]? {
        let lower = instruction.lowercased()
        if lower.contains("scroll down") || lower == "scroll" {
            return [AgentStep(kind: .scroll, description: "Scroll down one screen", target: "down")]
        }
        if lower.contains("scroll up") {
            return [AgentStep(kind: .scroll, description: "Scroll up one screen", target: "up")]
        }
        if lower.contains("scroll to top") || lower.contains("go to top") {
            return [AgentStep(kind: .scroll, description: "Scroll to the top", target: "top")]
        }
        if lower.contains("go back") || lower == "back" {
            return [AgentStep(kind: .back, description: "Go back", target: "")]
        }
        if lower.contains("reload") || lower.contains("refresh") {
            return [AgentStep(kind: .reload, description: "Reload the page", target: "")]
        }
        if lower.hasPrefix("go to ") || lower.hasPrefix("open ") {
            let target = instruction.dropFirst(lower.hasPrefix("go to ") ? 6 : 5)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            let url = target.contains("://") ? target : "https://\(target)"
            return [AgentStep(kind: .navigate, description: "Go to \(target)", target: url)]
        }
        if lower.hasPrefix("click ") {
            let target = String(instruction.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return nil }
            return [AgentStep(kind: .click, description: "Click “\(target)”", target: target)]
        }
        return nil
    }

    /// Parses the planner's JSON array. Tolerates surrounding prose and
    /// code fences; unknown kinds are dropped; caps at 8 steps.
    func parsePlanJSON(_ text: String) -> [AgentStep] {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = cleaned.firstIndex(of: "["), let end = cleaned.lastIndex(of: "]"), start < end {
            cleaned = String(cleaned[start...end])
        }
        guard let data = cleaned.data(using: .utf8),
              let raw = try? JSONDecoder().decode([AgentStep].self, from: data) else {
            return []
        }
        return Array(raw.prefix(8))
    }

    // MARK: - Running

    /// Runs the approved steps in order. Each step's result is logged.
    /// Call `stop()` to cancel mid-run.
    func run(_ steps: [AgentStep]) {
        guard !isRunning, !steps.isEmpty else { return }
        isRunning = true
        log.append(AgentLogEntry(text: "Running \(steps.count) approved step(s).", success: true))
        runTask = Task { [weak self] in
            guard let self else { return }
            for step in steps {
                if Task.isCancelled { break }
                let ok = await self.execute(step)
                self.log.append(AgentLogEntry(
                    text: "\(ok ? "Done" : "Failed"): \(step.description)",
                    success: ok
                ))
            }
            self.isRunning = false
            if Task.isCancelled {
                self.log.append(AgentLogEntry(text: "Stopped by the user.", success: true))
            } else {
                self.log.append(AgentLogEntry(text: "Run finished.", success: true))
            }
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    func clearLog() {
        log = []
    }

    /// The whole run as plain text, for saving as a chat record or note.
    var logText: String {
        log.map { entry in
            let mark = entry.success ? "✓" : "✗"
            return "\(mark) \(entry.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Execution

    private func execute(_ step: AgentStep) async -> Bool {
        guard let webView else { return false }
        switch step.kind {
        case .click:
            return await runJS(webView, Self.javascriptClick(matching: step.target))
        case .type:
            return await runJS(webView, Self.javascriptType(text: step.target, fieldHint: step.fieldHint))
        case .scroll:
            return await runJS(webView, Self.javascriptScroll(direction: step.target))
        case .navigate:
            guard let url = URL(string: step.target) else { return false }
            webView.load(URLRequest(url: url))
            return true
        case .back:
            if webView.canGoBack {
                webView.goBack()
                return true
            }
            return false
        case .reload:
            webView.reload()
            return true
        }
    }

    /// Runs JS and interprets the result as success (true / non-empty).
    private func runJS(_ webView: WKWebView, _ script: String) async -> Bool {
        do {
            let result = try await webView.evaluateJavaScript(script)
            if let bool = result as? Bool { return bool }
            if let number = result as? NSNumber { return number.boolValue }
            return result != nil
        } catch {
            return false
        }
    }

    /// A compact snapshot of the page for the planner: title, URL, and
    /// the visible clickable elements and fields (capped so the prompt
    /// stays small). Returns "" when there is no web view.
    private func pageSnapshot() async -> String {
        guard let webView else { return "(no page loaded)" }
        do {
            let result = try await webView.evaluateJavaScript(Self.javascriptSnapshot)
            if let json = result as? String, !json.isEmpty {
                return String(json.prefix(4_000))
            }
        } catch {
            // Fall through to the minimal snapshot below.
        }
        return "Title: \(webView.title ?? "")\nURL: \(webView.url?.absoluteString ?? "")"
    }

    // MARK: - JavaScript

    /// Returns a JSON string describing the page's clickable elements.
    static let javascriptSnapshot = """
    (() => {
      const textOf = (el) => (el.innerText || el.textContent || '').trim().replace(/\\s+/g, ' ');
      const links = [...document.querySelectorAll('a[href]')].slice(0, 40).map((a) => ({ t: textOf(a).slice(0, 60), h: a.getAttribute('href') || '' })).filter((x) => x.t);
      const buttons = [...document.querySelectorAll('button, [role="button"], input[type="submit"]')].slice(0, 20).map((b) => textOf(b).slice(0, 60)).filter(Boolean);
      const inputs = [...document.querySelectorAll('input, textarea, select')].slice(0, 10).map((i) => ({ type: i.type || i.tagName, ph: i.placeholder || '', name: i.name || '', label: i.getAttribute('aria-label') || '' }));
      return JSON.stringify({ title: document.title, url: location.href, links, buttons, inputs });
    })()
    """

    static func javascriptClick(matching text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          const needle = '\(escaped)'.toLowerCase();
          const els = [...document.querySelectorAll('a, button, [role="button"], input[type="submit"]')];
          const el = els.find((e) => (e.innerText || e.value || '').trim().toLowerCase().includes(needle));
          if (!el) return false;
          el.click();
          return true;
        })()
        """
    }

    static func javascriptType(text: String, fieldHint: String) -> String {
        let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
        let escapedHint = fieldHint.replacingOccurrences(of: "'", with: "\\'")
        return """
        (() => {
          const hint = '\(escapedHint)'.toLowerCase();
          const fields = [...document.querySelectorAll('input[type="text"], input[type="search"], input:not([type]), textarea')];
          let field = null;
          if (hint) {
            field = fields.find((f) => ((f.placeholder || '') + ' ' + (f.name || '') + ' ' + (f.getAttribute('aria-label') || '')).toLowerCase().includes(hint));
          }
          field = field || fields.find((f) => f.offsetParent !== null) || fields[0];
          if (!field) return false;
          const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
            || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
          if (setter) setter.call(field, '\(escapedText)'); else field.value = '\(escapedText)';
          field.dispatchEvent(new Event('input', { bubbles: true }));
          field.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })()
        """
    }

    static func javascriptScroll(direction: String) -> String {
        switch direction.lowercased() {
        case "up":
            return "window.scrollBy({top: -window.innerHeight, behavior: 'smooth'}); true;"
        case "top":
            return "window.scrollTo({top: 0, behavior: 'smooth'}); true;"
        default:
            return "window.scrollBy({top: window.innerHeight, behavior: 'smooth'}); true;"
        }
    }
}
