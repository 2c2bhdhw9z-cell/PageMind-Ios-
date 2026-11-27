import SwiftUI
import SwiftData
import UIKit
import WebKit

#if DEBUG
/// CI screenshot mode. `.github/workflows/screens.yml` launches the app
/// with `-uiShot <screen>` and photographs the simulator, so every screen
/// can be checked before a build goes to the owner. Debug builds only;
/// the .ipa is a Release build and never contains this.
enum ScreenshotMode {
    static var screen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-uiShot"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif

/// Closes the keyboard when the user taps anywhere that is not a text
/// field. Without this the chat box (a multi-line field, where Return
/// adds a new line) had no way to put the keyboard away.
///
/// One tap recogniser per window. `cancelsTouchesInView = false`, so the
/// tap still reaches the button underneath. Taps inside text fields and
/// web pages are ignored: ending editing there would fight the web
/// view's own focus handling.
@MainActor
final class KeyboardDismissTap: NSObject, UIGestureRecognizerDelegate {
    static let shared = KeyboardDismissTap()
    private var installedWindows = Set<ObjectIdentifier>()

    func install() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where !installedWindows.contains(ObjectIdentifier(window)) {
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                tap.cancelsTouchesInView = false
                tap.delegate = self
                window.addGestureRecognizer(tap)
                installedWindows.insert(ObjectIdentifier(window))
            }
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        recognizer.view?.endEditing(true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UITextField || current is UITextView || current is WKWebView {
                return false
            }
            view = current.superview
        }
        return true
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

/// Whether the App Group container is actually available to this build.
/// SwiftData fatally crashes inside ModelContainer init (instead of
/// throwing) when the group identifier has no entitlement, so callers
/// must check this BEFORE passing groupContainer: .identifier(...).
/// Unsigned CI / sideloaded builds have no entitlement and return nil.
enum AppGroup {
    static let identifier = "group.com.pagemind.app"
    static var isAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil
    }
}

@main
struct PageMindApp: App {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Chat.self,
            ChatMessage.self,
            SavedPage.self,
            CollectionModel.self,
        ])
        if AppGroup.isAvailable {
            let modelConfiguration = ModelConfiguration(
                schema: schema,
                isStoredInMemoryOnly: false,
                groupContainer: .identifier(AppGroup.identifier)
            )
            if let container = try? ModelContainer(for: schema, configurations: [modelConfiguration]) {
                return container
            }
        }
        // No App Group entitlement (CI / unsigned / sideloaded): local
        // on-disk store, then in-memory as a last resort. Data persists
        // per install but is not shared with extensions/widgets yet.
        do {
            return try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)]
            )
        } catch {
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    init() {
        // Registers the Morning Brief background task (BGTaskScheduler).
        // Registration must happen at launch, before the system can deliver
        // the task. If the brief is not enabled, registration is harmless.
        MorningBriefScheduler.register()
        #if DEBUG
        if let screen = ScreenshotMode.screen {
            UserDefaults.standard.set(screen != "onboarding", forKey: "hasSeenOnboarding")
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if hasSeenOnboarding {
                    AppShellView()
                } else {
                    OnboardingView()
                }
            }
            // Appearance settings (Settings → General) applied app-wide:
            // theme, text size, and display language. These read the
            // shared AppSettings instance, so changing them in Settings
            // takes effect immediately.
            .preferredColorScheme(AppSettings.shared.preferredColorScheme)
            .dynamicTypeSize(AppSettings.shared.preferredTypeSize)
            .environment(\.locale, AppSettings.shared.preferredLocale)
            // Keyboard: dragging any list or page down puts it away, and
            // so does tapping outside a text field.
            .scrollDismissesKeyboard(.interactively)
            .task {
                KeyboardDismissTap.shared.install()
            }
        }
        .modelContainer(sharedModelContainer)
        .environmentObject(AppSettings.shared)
    }
}

/// Shared in-memory handoff from Browser ("Ask about this page") to Chat.
/// BrowserView sets `pendingPage` and bumps `askRequestID`; AppShellView
/// switches to the Chat destination, and ChatView picks the page up as context.
@MainActor
final class PageContextStore: ObservableObject {
    @Published var pendingPage: SavedPage?
    @Published var askRequestID = UUID()

    func askAbout(page: SavedPage) {
        pendingPage = page
        askRequestID = UUID()
    }

    func takePendingPage() -> SavedPage? {
        defer { pendingPage = nil }
        return pendingPage
    }
}
