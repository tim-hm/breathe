import BreatheKit
import BreatheUI
import SwiftUI

/// The catalogue, and the watch app's root screen: one technique to a page,
/// turned with the Digital Crown.
///
/// Scroll it, tap it, breathe. A list would put every technique on screen at
/// once and none of them legibly, and it would spend a tap on a detail screen
/// between choosing and starting — on the wrist, choosing *is* starting. Each
/// page therefore carries everything the phone's detail screen carried that
/// matters here: the goal, the pattern, how long it takes, and the caution when
/// there is one.
struct TechniqueCarouselView: View {
    let model: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel

    /// The technique that was tapped, and what pushes the next screen. Held
    /// rather than passed to a link so nothing downstream is composed until
    /// somebody has actually chosen.
    @State private var chosen: Technique?

    var body: some View {
        content
            .navigationTitle("Breathe")
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink {
                        JourneyView(model: journey)
                    } label: {
                        // The phone's Journey tab icon. The same door gets the
                        // same handle on both devices, and it promises history
                        // rather than the settings a cog would — the watch has
                        // none, by design.
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(Theme.Ink.secondary)
                    }
                    // Plain, so this is a glyph at the edge rather than the
                    // filled accent capsule watchOS gives a toolbar button by
                    // default: the screen belongs to the technique on it, and a
                    // second bright control would compete with Begin.
                    .buttonStyle(.plain)
                    .accessibilityLabel("Your journey")
                }
            }
            // One destination that branches, so the carousel has one piece of
            // state rather than two nearly-identical ones. The drain is hung off
            // the session finishing rather than off a screen going away, because
            // a push counts as going away: every tap would otherwise start a
            // `GetJourney` round-trip in the same instant the extended runtime
            // session does.
            .navigationDestination(item: $chosen) { technique in
                if technique.safetyNote == nil {
                    SessionView(model: session(for: technique)) {
                        Task { await journey.sync() }
                    }
                } else {
                    CautionView(technique: technique, sessions: sessions) {
                        Task { await journey.sync() }
                    }
                }
            }
            .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()

        case let .loaded(techniques):
            TabView {
                ForEach(techniques) { technique in
                    page(technique)
                }
            }
            .tabViewStyle(.verticalPage)

        case let .failed(message):
            // Only reachable on a first-ever launch out of range: every later
            // failure is served from `CachedTechniqueRepository`'s copy of the
            // last catalogue the server sent.
            unreachable(message)
        }
    }

    /// One technique, filling the screen and tappable anywhere on it.
    ///
    /// The whole card is the button rather than the "Begin" line alone: at this
    /// size a target the width of two words is one somebody misses, and there is
    /// nothing else on the page a tap could have meant.
    private func page(_ technique: Technique) -> some View {
        Button {
            chosen = technique
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                HStack(spacing: Theme.Spacing.tight) {
                    Circle()
                        .fill(technique.goal.accent)
                        .frame(width: 6, height: 6)
                    Text(technique.goal.intentObject)
                        .font(.caption2)
                        .foregroundStyle(technique.goal.accent)
                }

                Text(technique.name)
                    .font(.headline)
                    .foregroundStyle(Theme.Ink.primary)

                HStack(alignment: .firstTextBaseline) {
                    Text(cadence(technique))
                        .accessibilityLabel("Pattern")
                        .accessibilityValue(cadence(technique))
                    Spacer(minLength: Theme.Spacing.tight)
                    Text(technique.plannedDuration.formatted(.time(pattern: .minuteSecond)))
                        .foregroundStyle(Theme.Ink.tertiary)
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.secondary)

                // A marker, not the caution itself. The longest one in the
                // catalogue is eight lines on this screen and there is no
                // honest way to abbreviate a contraindication, so the card
                // says there is one and `CautionView` says what it is.
                Label(
                    technique.safetyNote == nil ? "Begin" : "Caution — read first",
                    systemImage: technique.safetyNote == nil
                        ? "play.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(
                    technique.safetyNote == nil ? technique.goal.accent : Theme.Accent.caution
                )
                .padding(.top, Theme.Spacing.tight)
            }
            // Hugging its content and centred, rather than filling the page: a
            // technique with no caution would otherwise leave a third of the
            // card empty above the Begin line.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.close)
            .background(Theme.Surface.raised.opacity(0.5), in: card)
            .overlay(card.stroke(technique.goal.accent.opacity(0.35)))
        }
        .buttonStyle(.plain)
        // Clear of the vertical page indicator, which draws over the right edge
        // — without this the card runs under the dots and looks cropped.
        .padding(.trailing, Theme.Spacing.close)
    }

    private var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.card)
    }

    /// The pattern in seconds — "4 · 4 · 4 · 4" — which is the one thing about a
    /// technique somebody checks before starting it.
    ///
    /// Read off the first stage only. A staged protocol has no single cadence to
    /// state, and the honest short answer for one is how it opens.
    private func cadence(_ technique: Technique) -> String {
        guard let stage = technique.stages.first else { return "" }
        return stage.phases
            .map { $0.duration.seconds.formatted(.number.precision(.fractionLength(0 ... 1))) }
            .joined(separator: " · ")
    }

    /// Built at the tap rather than held: a session is a one-shot object, and
    /// one composed when this screen appeared would already have been used by
    /// the time somebody comes back and starts again.
    private func session(for technique: Technique) -> SessionModel {
        SessionModel(
            technique: technique,
            cues: WatchHapticController(),
            recorder: sessions
        )
    }

    private func unreachable(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Can't reach the catalogue", systemImage: "wifi.slash")
        } description: {
            Text(message)
        } actions: {
            Button("Try again") {
                Task { await model.load() }
            }
        }
    }
}
