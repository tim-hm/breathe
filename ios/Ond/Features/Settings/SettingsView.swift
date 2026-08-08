import OndKit
import OndUI
import StoreKit
import SwiftUI

/// The app's few dials, plus the reminder schedules and the subscription.
///
/// Pushed from Journey's toolbar gear, so it brings no navigation of its own —
/// the stack it draws its title and its back button in is Journey's, which is
/// also what lets `SchedulesView` push one deeper from here.
///
/// The profile link leads the screen because it is the one row about the person
/// rather than about the app: onboarding asked why they were here and then never
/// asked again, and the answers it took are the ones most likely to have gone
/// stale. It sits above Appearance for that reason and no other.
///
/// The subscription row is a reversal. It used to be offered only where the
/// reason to buy was already on screen — a locked exercise, or the assistant
/// strip that named one — on the theory that a Settings row would be an entry
/// point with no reason beside it. Those surfaces are all conditional, and
/// that proved the flaw: people reported finding no way to turn the coach on
/// at all. Settings is where everybody looks for "what am I paying for", so
/// this row now names the tier unconditionally and opens the paywall to
/// change it.
///
/// The account rows are here on the same reasoning and one more: signing in is
/// never a gate, so the only place it can live is where somebody goes looking
/// for it.
///
/// The two legal links below it repeat the paywall's pair on purpose. App
/// Review expects both reachable outside a purchase flow, and somebody
/// deciding whether to trust the app with their breathing history should not
/// have to open an offer to read what is collected.
struct SettingsView: View {
    let catalogue: TechniqueListModel

    /// The onboarding answers, to edit. A parameter like `catalogue` rather than
    /// an environment value, because the screen that pushes this one already
    /// holds the store for the leaderboard card beside the gear.
    let profiles: ProfileStore

    /// Schedules live behind a link here rather than a tab: set once, edited
    /// rarely, and the notification tray is their daily face. From the
    /// environment for the reason `settings` is: this screen is two pushes below
    /// a tab root that has no use for the store, and a parameter would make
    /// every view in between carry one.
    @Environment(ScheduleStore.self) private var schedules
    @Environment(SessionSettings.self) private var settings
    @Environment(SubscriptionStore.self) private var plus
    @Environment(AccountModel.self) private var account

    @State private var isShowingPaywall = false
    @State private var isManagingSubscription = false

    var body: some View {
        @Bindable var settings = settings
        @Bindable var health = LiveHealth.model

        List {
            Section {
                NavigationLink("Profile") {
                    ProfileView(profiles: profiles)
                }
            } footer: {
                Text("What you told us when you started — why you're here, how "
                    + "much we explain as you go, and what your coach knows "
                    + "about you. Change any of it whenever you like.")
            }
            .listRowBackground(Theme.Surface.raised)

            Section {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(Appearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
            }
            .listRowBackground(Theme.Surface.raised)

            Section {
                NavigationLink {
                    SchedulesView(store: schedules, catalogue: catalogue)
                } label: {
                    LabeledContent("Schedules") {
                        Text(scheduleSummary)
                    }
                }
            } footer: {
                Text("A standing time for an exercise — box breathing every "
                    + "weekday at 8, say. iOS asks for notification "
                    + "permission when you set your first one.")
            }
            .listRowBackground(Theme.Surface.raised)

            Section {
                Picker("Cues", selection: $settings.cueMode) {
                    ForEach(SessionCueMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Picker("Vibration", selection: $settings.hapticStrength) {
                    ForEach(HapticStrength.allCases) { strength in
                        Text(strength.title).tag(strength)
                    }
                }
                // Beside Cues rather than folded into it, and dimmed by it:
                // a strength control under a mode that plays no haptics is
                // a dial connected to nothing.
                .disabled(!settings.cueMode.playsHaptics)

                Picker("Guidance", selection: $settings.guidance) {
                    ForEach(SessionGuidance.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text(
                    "Full guidance keeps the instruction, the countdown, and any "
                        + "hints on screen. Just the visuals leaves the orb to guide "
                        + "you. Where an exercise carries a caution, it shows either way."
                )
            }
            .listRowBackground(Theme.Surface.raised)

            Section {
                Toggle("Let the coach see heart trends", isOn: $health.coachReadsHeartTrends)
            } footer: {
                Text(
                    "Coarse weekly trends from Health — resting heart rate and its "
                        + "variability — travel with your coach requests only, and are "
                        + "never stored. Turning this on asks for Health access."
                )
            }
            .listRowBackground(Theme.Surface.raised)

            Section {
                Button {
                    isShowingPaywall = true
                } label: {
                    LabeledContent("Subscription") {
                        Text(plus.tier.brandedTitle)
                    }
                }
                // Plain, so the row reads like its neighbours: its first
                // job is to answer "which tier", and only then to open the
                // sheet for whoever asks more of it.
                .buttonStyle(.plain)

                if plus.tier > .free {
                    Button("Manage subscription") {
                        isManagingSubscription = true
                    }
                    .tint(Theme.Accent.brand)
                }
            }
            .listRowBackground(Theme.Surface.raised)

            AccountSection(account: account, isManagingSubscription: $isManagingSubscription)

            Section {
                Link("Privacy", destination: LegalLinks.privacyPolicy)
                Link("Terms", destination: LegalLinks.termsOfUse)
            }
            .listRowBackground(Theme.Surface.raised)
        }
        .paletteGround()
        .paywall(highlighting: offeredTier, isPresented: $isShowingPaywall)
        .manageSubscriptionsSheet(isPresented: $isManagingSubscription)
        .navigationTitle("Settings")
    }

    /// The rung above the current one, which is what the paywall should lead
    /// with — the sheet is a ladder, and the interesting question from here is
    /// always the next step up. Derived from the ladder rather than written out
    /// beside it, like every other tier comparison. A subscriber on the top
    /// rung has nothing above, so their sheet opens on what they already hold,
    /// which reads as confirmation.
    private var offeredTier: SubscriptionTier {
        SubscriptionTier.purchasable.first { $0 > plus.tier } ?? plus.tier
    }

    /// "2 active" beside the link — enough to know the feature is in use
    /// without opening it. Disabled schedules deliberately don't count.
    private var scheduleSummary: String {
        let active = schedules.schedules.count(where: \.isEnabled)
        return active == 0 ? "None" : "\(active) active"
    }
}
