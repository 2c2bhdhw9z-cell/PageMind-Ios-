import SwiftUI
import StoreKit

/// Paywall for PageMind Pro, shown as a sheet with a close button
/// (from the menu's Upgrade button, Settings, and the Browser Agent).
///
/// Monthly $4.99 / Lifetime $24.99 (launch price $19.99).
/// Buttons are wired to StoreManager. If no products are available yet
/// (no App Store Connect products — see StoreManager), the view says so
/// instead of showing prices that cannot be bought.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PaywallContent()
                    .padding(16)
            }
            .background(PageMindDesign.appBackground.ignoresSafeArea())
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
        }
    }
}

/// The paywall itself, without a sheet around it. Also shown in place
/// of a Pro tool (Deep Research, Compare, Morning Brief) for free users.
struct PaywallContent: View {
    @StateObject private var store = StoreManager.shared

    private let features = [
        ("safari", "Browser Agent", "Ask PageMind to click, type and scroll for you in the in-app browser — every step approved by you."),
        ("doc.text.magnifyingglass", "Deep Research", "A research report on any topic, written from several web sources, with citations."),
        ("rectangle.split.2x1", "Side-by-side compare", "Ask two models the same question and see both answers side by side."),
        ("sunrise", "Morning Brief", "A summary of your saved pages and topics, ready each morning.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("PageMind Pro")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                Text("For readers who want PageMind to do more of the work.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(PageMindDesign.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 16) {
                ForEach(features, id: \.1) { icon, title, detail in
                    HStack(alignment: .top, spacing: 12) {
                        IconChip(systemImage: icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title)
                                .font(.subheadline.weight(.semibold))
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(PageMindDesign.elevatedCard)
            )

            if store.products.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text("Pro can't be bought yet. It opens when PageMind is on the App Store.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
            } else {
                VStack(spacing: 12) {
                    if let monthly = store.monthlyProduct {
                        Button("Monthly — \(monthly.displayPrice) / month") {
                            Task { await store.purchase(monthly) }
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(PageMindDesign.brandGradient)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if let lifetime = store.lifetimeProduct {
                        Button("Lifetime — \(lifetime.displayPrice) (launch price $19.99)") {
                            Task { await store.purchase(lifetime) }
                        }
                        .font(.headline)
                        .foregroundStyle(PageMindDesign.brandIndigo)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(PageMindDesign.elevatedCard)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(PageMindDesign.brandIndigo.opacity(0.4), lineWidth: 1)
                        )
                    }
                }
            }

            Button("Restore purchases") {
                Task { await store.restore() }
            }
            .font(.subheadline)
            .foregroundStyle(PageMindDesign.brandIndigo)
            .frame(maxWidth: .infinity)

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text("Pro unlocks features. Your AI key stays yours: PageMind never holds it or charges you for AI use. You pay your AI provider directly, or use free models.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            await store.loadProducts()
        }
    }
}
