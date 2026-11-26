import SwiftUI

/// Shared Pro gating for all Pro screens.
///
/// When `StoreManager.shared.isPro` is false, the paywall is shown
/// instead of the feature. `isPro` stays false until the App Store
/// Connect products exist and a real purchase is made — nothing here
/// fakes a purchase.
struct ProGate<Content: View>: View {
    @StateObject private var store = StoreManager.shared
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if store.isPro {
            content
        } else {
            VStack(spacing: 16) {
                Text("This is a Pro feature.")
                    .font(.headline)
                PaywallView()
            }
        }
    }
}

/// One agent log line, shown in the Browser Agent panel and saved with
/// the run's chat record.
struct AgentLogEntry: Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var text: String
    var success: Bool
}
