import BreatheKit
import BreatheUI
import SwiftUI

/// What Plus is, what it costs, and the two links App Review will not approve a
/// paywall without.
///
/// The copy leads with what stays free, which is the honest framing and also the
/// product's: the catalogue, the player, the journey, and the boards are the
/// hero experience and are not for sale. What Plus buys is the one feature that
/// costs money to run — the assistant asking a language model on this person's
/// behalf. A paywall that implied otherwise would be selling something the app
/// already gives away.
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    /// From the environment, like `SessionSettings`: `BreatheApp` owns the one
    /// instance, and the surfaces that offer Plus are nowhere near it.
    @Environment(PlusStore.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.loose) {
                    header
                    benefits
                    free
                }
                .padding(Theme.Spacing.standard)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.Surface.ground)
            .safeAreaInset(edge: .bottom) { purchaseBar }
            .navigationTitle("Breathe Plus")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            // Dismisses itself the moment the purchase lands, rather than
            // leaving somebody looking at a paywall for something they now own.
            .onChange(of: store.isPlus) { _, isPlus in
                if isPlus {
                    dismiss()
                }
            }
            // The price is fetched here rather than at launch: it is the one
            // App Store round trip this app makes, and only this screen needs
            // it.
            .task { await store.loadProduct() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text("The assistant, in full")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Theme.Ink.primary)

            Text(
                """
                Breathe is free, and stays free. Plus opens up the one part that \
                costs us to run — an assistant that reads what you told us and \
                answers in your words rather than from a script.
                """
            )
            .font(.body)
            .foregroundStyle(Theme.Ink.secondary)
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.standard) {
            benefit(
                icon: "sparkles",
                title: "Guidance written for you",
                detail: "Where to start, re-tuned as your practice changes."
            )
            benefit(
                icon: "text.book.closed",
                title: "Why a technique works",
                detail: "Explained at your level, for any technique in the catalogue."
            )
            benefit(
                icon: "infinity",
                title: "Ask as often as you like",
                detail: "The free tier gets a taste each day. Plus lifts the ceiling."
            )
        }
        .padding(Theme.Spacing.standard)
        .background(Theme.Surface.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func benefit(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.standard) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.Accent.brand)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.Ink.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.Ink.secondary)
            }
        }
    }

    private var free: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.close) {
            Text("Always free")
                .font(.headline)
                .foregroundStyle(Theme.Ink.primary)

            Text(
                """
                Every technique, the guided player with haptics and sound, your \
                whole journey, the leaderboards, and the Apple Watch app.
                """
            )
            .font(.subheadline)
            .foregroundStyle(Theme.Ink.secondary)
        }
    }

    /// Pinned to the bottom, because the price, the button, and the two required
    /// links have to be reachable without reading to the end of the page.
    private var purchaseBar: some View {
        VStack(spacing: Theme.Spacing.close) {
            Button {
                Task { await store.purchase() }
            } label: {
                Text(callToAction)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.Accent.brand)
            .disabled(store.isBusy)

            if store.isAwaitingApproval {
                Text("Waiting for approval. You'll get Plus as soon as it comes through.")
                    .font(.footnote)
                    .foregroundStyle(Theme.Ink.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Renews yearly. Cancel any time in Settings.")
                .font(.caption)
                .foregroundStyle(Theme.Ink.tertiary)

            HStack(spacing: Theme.Spacing.standard) {
                Button("Restore Purchases") {
                    Task { await store.restore() }
                }
                .disabled(store.isBusy)

                Link("Privacy", destination: LegalLinks.privacyPolicy)
                Link("Terms", destination: LegalLinks.termsOfUse)
            }
            .font(.footnote)
            .tint(Theme.Accent.brand)
        }
        .padding(Theme.Spacing.standard)
        .background(.bar)
    }

    /// The price comes from the App Store or not at all: it varies by
    /// storefront, and a hardcoded "$4.99" would be wrong in most countries and
    /// illegal in a few. A missing price reads as a plain call to action rather
    /// than a blank — somebody with no signal can still see what Plus is and buy
    /// it when the sheet loads.
    private var callToAction: String {
        guard let price = store.product?.displayPrice else { return "Get Plus" }

        return "Get Plus — \(price) a year"
    }
}
