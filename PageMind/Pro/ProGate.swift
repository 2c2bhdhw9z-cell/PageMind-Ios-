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
            // The paywall's content inline, under the screen's own top
            // bar. (Before, a whole paywall sheet was embedded here, with
            // a Close button that could not close anything.)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label("Part of PageMind Pro", systemImage: "lock.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PageMindDesign.brandIndigo)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(PageMindDesign.brandIndigo.opacity(0.15)))
                    PaywallContent()
                }
                .padding(16)
            }
            .scrollBounceBehavior(.basedOnSize)
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
