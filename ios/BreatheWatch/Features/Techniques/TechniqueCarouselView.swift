import BreatheKit
import BreatheUI
import SwiftUI

/// The catalogue: one technique to a page, turned with the Digital Crown.
///
/// Shaped like a Fitness workout card, and for the same reason — a wrist screen
/// holds one picture, one name, and one button before it stops being glanceable.
/// Everything that used to sit on the card (the intent word, the cadence, the
/// summary) has gone: none of it is read while choosing on a watch, and all of
/// it is a tap away in the hand.
struct TechniqueCarouselView: View {
    let model: TechniqueListModel
    let sessions: any SessionRecording
    let journey: JourneyModel

    /// The technique that was tapped, and what pushes the next screen. Held
    /// rather than passed to a link so nothing downstream is composed until
    /// somebody has actually chosen.
    @State private var chosen: Technique?

    @Environment(WatchSettings.self) private var settings

    var body: some View {
        content
            .navigationTitle("Exercises")
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

    /// One technique: its orb, its name, and the button that starts it.
    private func page(_ technique: Technique) -> some View {
        VStack(spacing: Theme.Spacing.close) {
            TechniqueGlyph(technique: technique)
                .frame(height: 76)
                .padding(.horizontal, Theme.Spacing.close)
                .overlay(alignment: .topTrailing) {
                    if technique.safetyNote != nil {
                        cautionBadge
                    }
                }

            VStack(spacing: 0) {
                Text(technique.name)
                    .font(.caption)
                    .foregroundStyle(Theme.Ink.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)

                // The one number that survived the redesign, because it is the
                // one that changes the answer: two minutes and nine minutes are
                // different decisions, and the rest of what a card used to carry
                // is not read on a wrist.
                Text(technique.plannedDuration.formatted(.time(pattern: .minuteSecond)))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Ink.tertiary)
            }
            .accessibilityElement(children: .combine)

            play(technique)
        }
        // Clear of the vertical page indicator, which draws over the right edge.
        .padding(.trailing, Theme.Spacing.close)
    }

    /// Fitness's play button, in the technique's colour: the one control on the
    /// page, and big enough to hit without looking.
    private func play(_ technique: Technique) -> some View {
        Button {
            chosen = technique
        } label: {
            Image(systemName: "play.fill")
                .font(.title3)
                .foregroundStyle(Theme.Surface.ground)
                .frame(width: 42, height: 42)
                .background(technique.goal.accent, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Begin \(technique.name)")
        .accessibilityHint(technique.safetyNote == nil ? "" : "Shows a caution first")
    }

    /// A marker, not the caution itself. The longest one in the catalogue is
    /// eight lines on this screen and there is no honest way to abbreviate a
    /// contraindication, so the page says there is one and `CautionView` says
    /// what it is.
    private var cautionBadge: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(Theme.Accent.caution)
            .accessibilityHidden(true)
    }

    /// Built at the tap rather than held: a session is a one-shot object, and
    /// one composed when this screen appeared would already have been used by
    /// the time somebody comes back and starts again.
    private func session(for technique: Technique) -> SessionModel {
        SessionModel(
            technique: technique,
            cues: WatchHapticController(settings: settings),
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
