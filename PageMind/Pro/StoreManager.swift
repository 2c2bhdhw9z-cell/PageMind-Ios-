import Foundation
import StoreKit

/// StoreKit 2 manager for PageMind Pro.
///
/// Product IDs:
/// - pagemind.pro.monthly  ($4.99 / month)
/// - pagemind.pro.lifetime ($24.99, $19.99 at launch)
///
/// Honest sideload note: StoreKit only returns real products and
/// entitlements once the products exist in App Store Connect and the app
/// runs through TestFlight / the App Store (or a StoreKit sandbox /
/// configuration file in Xcode). With no Apple Developer account and no
/// App Store Connect products yet, `loadProducts()` returns an empty list
/// and `isPro` stays false. The paywall explains that. Nothing here fakes
/// a purchase or unlocks Pro locally.
@MainActor
final class StoreManager: ObservableObject {
    /// One shared instance for the whole app. Each StoreManager listens to
    /// StoreKit's Transaction.updates, so creating one per view would spawn
    /// a listener per view; use this instead.
    static let shared = StoreManager()

    static let monthlyProductID = "pagemind.pro.monthly"
    static let lifetimeProductID = "pagemind.pro.lifetime"

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published var errorMessage: String?

    private var updatesTask: Task<Void, Never>?

    var isPro: Bool {
        purchasedProductIDs.contains(Self.monthlyProductID)
            || purchasedProductIDs.contains(Self.lifetimeProductID)
    }

    var monthlyProduct: Product? {
        products.first { $0.id == Self.monthlyProductID }
    }

    var lifetimeProduct: Product? {
        products.first { $0.id == Self.lifetimeProductID }
    }

    init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                await self.handleTransactionResult(result)
            }
        }
        Task { await refreshEntitlements() }
    }

    // No deinit cancel: the updates task holds only a weak self, so it
    // exits on its own when this manager is deallocated. (A deinit that
    // touched MainActor-isolated state would also be a Swift 6 isolation error.)

    func loadProducts() async {
        do {
            products = try await Product.products(for: [
                Self.monthlyProductID,
                Self.lifetimeProductID
            ])
            await refreshEntitlements()
        } catch {
            // Expected before App Store Connect products exist (see note above).
            errorMessage = "Products are not available yet: \(error.localizedDescription)"
            products = []
        }
    }

    func purchase(_ product: Product) async {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handleTransactionResult(verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            errorMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Private

    private func refreshEntitlements() async {
        var ids = Set<String>()
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.revocationDate == nil {
                ids.insert(transaction.productID)
            }
        }
        purchasedProductIDs = ids
    }

    private func handleTransactionResult(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        if transaction.revocationDate == nil {
            purchasedProductIDs.insert(transaction.productID)
        } else {
            purchasedProductIDs.remove(transaction.productID)
        }
        await transaction.finish()
    }
}
