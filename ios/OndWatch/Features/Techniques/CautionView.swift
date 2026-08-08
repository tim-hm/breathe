import OndKit
import OndStyle
import OndUI
import SwiftUI

/// The one screen that stands between choosing a technique and breathing it.
///
/// The wrist's answer to the phone's in-session caution, and the reason the
/// watch kept one at all when the browsing surfaces lost theirs. The two
/// exercises that can make somebody faint reach here; the other seven go
/// straight from the carousel into the session, as does everything once the
/// consent step in the phone's onboarding has named the general hazards.
///
/// A screen rather than a line under the breath guide, because the alternative
/// was worse in both directions. The longest caution in the catalogue runs to
/// eight lines on a 46mm screen: it does not fit on a carousel page, it does not
/// fit beside a phase countdown, and the only way to make it fit either is to
/// truncate it — which is the one thing a contraindication may never do.
struct CautionView: View {
    let technique: Technique
    let sessions: any SessionRecording
    let onFinished: () -> Void

    @State private var isBreathing = false

    @Environment(WatchSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                SafetyNote(technique: technique)

                Button("Begin") {
                    isBreathing = true
                }
                .tint(technique.goal.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(technique.name)
        // A destination behind a flag rather than a `NavigationLink`, because a
        // link's destination is built with the view it sits in: the session —
        // and the timeline it lays out — would be composed on every pass over
        // this body, and re-composed for a screen nobody opened.
        .navigationDestination(isPresented: $isBreathing) {
            SessionView(model: session(), onFinished: onFinished)
        }
    }

    /// Built at the tap rather than held: a session is a one-shot object, and
    /// one composed when this screen appeared would already have been used by
    /// the time somebody comes back and starts again.
    private func session() -> SessionModel {
        SessionModel(
            technique: technique,
            cues: WatchHapticController(settings: settings),
            recorder: sessions
        )
    }
}
