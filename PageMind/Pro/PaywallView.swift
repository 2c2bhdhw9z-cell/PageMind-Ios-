import SwiftUI
import StoreKit

/// Paywall for PageMind Pro.
///
/// Monthly $4.99 / Lifetime $24.99 (launch price $19.99).
/// Buttons are wired to StoreManager. If no products are available yet
/// (no App Store Connect products — see StoreManager), the view says so
/// instead of showing prices that cannot be bought.
struct PaywallView: View {
    @StateObject private var store = StoreManager.shared
    @Environment(\.dismiss) private var dismiss

    private let features = [
        ("safari", "Browser Agent", "Ask PageMind to click, type and scroll for you in the in-app browser — every step approved by you."),
        ("rectangle.on.rectangle", "Side-by-side compare", "Run the same question on two models and compare the answers."),
        ("sun.max", "Morning Brief", "A scheduled summary of your saved pages and topics, ready each morning."),
        ("magnifyingglass", "Deep Research", "A multi-source research report on any topic, with citations.")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Gradient hero: the paywall's designed anchor.
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .background(Color.white.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 15))
                        Text("PageMind Pro")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.white)
                        Text("For readers who want PageMind to do more of the work.")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(PageMindDesign.brandGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .shadow(color: PageMindDesign.brandIndigo.opacity(0.35), radius: 16, x: 0, y: 6)

                    ForEach(features, id: \.1) { icon, title, detail in
                        HStack(alignment: .top, spacing: 12) {
                            IconChip(systemImage: icon)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title).font(.headline)
                                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if store.products.isEmpty {
                        Text("Purchases are not available yet — Pro products are still being set up in App Store Connect. Check back soon.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(PageMindDesign.elevatedCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                                .clipShape(RoundedRectangle(cornerRadius: 14))
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
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(PageMindDesign.brandIndigo.opacity(0.4), lineWidth: 1)
                                )
                            }
                        }
                    }

                    Button("Restore purchases") {
                        Task { await store.restore() }
                    }
                    .foregroundStyle(PageMindDesign.brandIndigo)
                    .frame(maxWidth: .infinity)

                    if let error = store.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }

                    Text("Pro is a feature unlock — your AI key is still yours. PageMind never holds your key or charges you for AI use; you pay your provider directly (or use free models).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task {
                await store.loadProducts()
            }
        }
    }
}
