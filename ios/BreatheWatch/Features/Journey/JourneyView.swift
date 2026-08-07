import BreatheKit
import BreatheUI
import SwiftUI

/// What this person has done, at wrist size.
///
/// Local-fold-first exactly like the phone's: every number here comes from the
/// sessions on this device, so the screen is complete before the sync it starts
/// has finished — and just as complete with the phone in another room. Once an
/// identity has arrived, that file holds the phone's history too: the sync's
/// restore path pulls back what the server has, so a streak counts both wrists
/// and hands rather than only what was breathed here.
///
/// No leaderboards. They are other people, so they need a connection, and a
/// screen that is sometimes blank is not one worth a crown scroll.
struct JourneyView: View {
    let model: JourneyModel

    /// The phone's best controlled pause, mirrored over WatchConnectivity. Read
    /// from the environment rather than passed in, so the catalogue screen that
    /// links here does not carry a number it never renders. Not off
    /// `JourneyModel`, whose personal best is folded from scores measured on
    /// *this* device — and the BOLT test is a phone screen.
    @Environment(PhoneLink.self) private var phone

    var body: some View {
        List {
            Section {
                Text(model.stats.streakHeadline)
                    .font(.headline)
                    .foregroundStyle(Theme.Ink.primary)
                Text(model.stats.streakDetail)
                    .font(.caption2)
                    .foregroundStyle(Theme.Ink.secondary)
            }

            Section("Totals") {
                total("Sessions", "\(model.stats.sessions)")
                total("Minutes", "\(model.stats.minutes)")
                total("Breaths", "\(model.stats.breaths)")
                if let best = phone.boltBestSeconds {
                    total("Best pause", "\(best)s")
                }
            }

            if !model.history.isEmpty {
                Section("Recent") {
                    // Five, because that is what fits before a crown scroll
                    // stops being a glance — the phone's journey tab is where
                    // somebody reads the whole journal.
                    ForEach(model.history.prefix(5)) { record in
                        recent(record)
                    }
                }
            }
        }
        .navigationTitle("Journey")
        // Local only. The network drains are owned by the moments that change
        // something — launch, an identity arriving, a session finishing — so
        // opening this screen re-reads the file and touches nothing else.
        .task { await model.refresh() }
    }

    private func total(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.primary)
        }
        .font(.caption)
        .foregroundStyle(Theme.Ink.secondary)
        .accessibilityElement(children: .combine)
    }

    private func recent(_ record: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(record.startedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                .font(.caption)
                .foregroundStyle(Theme.Ink.primary)
            Text(record.duration.formatted(.time(pattern: .minuteSecond)))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.Ink.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
