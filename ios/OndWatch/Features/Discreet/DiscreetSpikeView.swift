#if DEBUG
    import Foundation
    import Observation
    import OndKit
    import os
    import SwiftUI
    import WatchKit

    /// The instrument discreet mode has to be built on top of, and nothing that
    /// ships: `#if DEBUG` keeps it out of every release build, and the row that
    /// reaches it is behind the same fence.
    ///
    /// Two things about a thirty-minute discreet session are unknowable off a
    /// wrist, and the watch simulator will answer both confidently and wrongly —
    /// exactly as the phone simulator reported a healthy locked-screen session
    /// that did not exist on the device. So they get measured rather than assumed:
    ///
    /// 1. **Does an extended runtime session last half an hour?** These are
    ///    time-limited and the ceiling depends on the session type. A discreet
    ///    session is the longest thing this app would ever ask for, and longer
    ///    than any session the watch runs today.
    /// 2. **Do haptics still arrive after a long silence?** The cadence is
    ///    deliberately sparse, up to thirteen minutes between bursts, and a
    ///    session that stays alive while doing nothing at all is a different
    ///    proposition from one accompanying continuous cueing.
    ///
    /// The log separates the two, which is the whole reason it exists. Each entry
    /// is written by the app *deciding* to tap; whether anything was felt is
    /// something only the person wearing it can say. A burst that appears here and
    /// was not felt means haptics are being withheld; a burst that never appears
    /// means the runtime went away, and the reason it went away is logged beside
    /// it.
    ///
    /// Its own `WKExtendedRuntimeSession` rather than the shipping
    /// `ExtendedRuntime`, deliberately: that type documents having no state a view
    /// can react to, and bending a shipping design to serve a temporary instrument
    /// is how instruments become permanent.
    @MainActor
    @Observable
    final class DiscreetSpike: NSObject {
        /// One thing that happened, and when — the elapsed time being the only
        /// clock that matters here, since the question is about intervals.
        struct Entry: Identifiable {
            let id: Int
            let elapsed: Duration
            let what: String
        }

        private(set) var log: [Entry] = []
        private(set) var isRunning = false

        private nonisolated static let logger = Logger(category: "discreet-spike")

        private var session: WKExtendedRuntimeSession?
        private var cadence: Task<Void, Never>?
        private var started: ContinuousClock.Instant?

        /// How far into the run the wrist is, or zero before it starts.
        var elapsed: Duration {
            started.map { ContinuousClock.now - $0 } ?? .zero
        }

        /// Runs the real cadence over `technique`, cued through the same
        /// controller a full-screen session uses so the taps under test are the
        /// taps that would ship.
        ///
        /// - Parameters:
        ///   - technique: what a burst is six breaths of.
        ///   - cues: the wrist's cue controller, which honours the haptics
        ///     switch — a run with haptics off proves nothing, and the log will
        ///     still say the bursts fired.
        func start(technique: Technique, cues: some SessionCueing) {
            guard !isRunning else { return }

            let started = ContinuousClock.now
            isRunning = true
            log = []
            self.started = started
            note("spike started")

            let session = WKExtendedRuntimeSession()
            session.delegate = self
            self.session = session
            session.start()

            cadence = Task { await run(technique: technique, cues: cues, from: started) }
        }

        /// Stops early, by hand. Not the thing being measured — a run that
        /// answers the questions ends by itself.
        func end() {
            cadence?.cancel()
            cadence = nil
            release()
        }

        private func run(
            technique: Technique,
            cues: some SessionCueing,
            from started: ContinuousClock.Instant
        ) async {
            let burst = DiscreetCadence.burst(of: technique)
            let clock = ContinuousClock()

            for (index, burstStart) in DiscreetCadence.burstStarts.enumerated() {
                // Sleeping to an absolute deadline rather than for a gap's
                // length: a wake-up the system delayed by a minute must not
                // push every later burst by a minute too, or a late schedule
                // would read as a missing one.
                do {
                    try await clock.sleep(until: started.advanced(by: burstStart))
                } catch {
                    return
                }

                note("burst \(index + 1) fired, \(burst.beats.count) taps")

                for beat in burst.beats {
                    do {
                        try await clock.sleep(until: started.advanced(by: burstStart + beat.start))
                    } catch {
                        return
                    }
                    cues.play(beat)
                }
            }

            note("cadence complete")
            release()
        }

        /// Hands the runtime budget back. Separate from `end()` so the run can
        /// finish without cancelling the task it is the last statement of.
        private func release() {
            session?.invalidate()
            session = nil
            isRunning = false
        }

        private func note(_ what: String) {
            Self.logger.notice("\(what, privacy: .public)")
            log.append(Entry(id: log.count, elapsed: elapsed, what: what))
        }
    }

    /// Mirrors `ExtendedRuntime`'s isolation dance: WatchKit calls these on the
    /// main thread but the protocol carries no isolation, so the ones that touch
    /// state hop explicitly.
    extension DiscreetSpike: WKExtendedRuntimeSessionDelegate {
        nonisolated func extendedRuntimeSessionDidStart(_: WKExtendedRuntimeSession) {
            Task { @MainActor in self.note("runtime started") }
        }

        nonisolated func extendedRuntimeSessionWillExpire(_: WKExtendedRuntimeSession) {
            Task { @MainActor in self.note("runtime will expire") }
        }

        nonisolated func extendedRuntimeSession(
            _: WKExtendedRuntimeSession,
            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
            error: (any Error)?
        ) {
            // The reason is the answer to the duration question, so it is spelt
            // out rather than logged as a raw value somebody then has to look
            // up on a watch screen.
            let cause = switch reason {
            case .expired: "expired"
            case .resignedFrontmost: "resigned frontmost"
            case .suppressedBySystem: "suppressed by system"
            case .sessionInProgress: "another session in progress"
            case .error: "error: \(error?.localizedDescription ?? "unknown")"
            case .none: "none"
            @unknown default: "unknown (\(reason.rawValue))"
            }

            Task { @MainActor in self.note("runtime ended: \(cause)") }
        }
    }

    /// The spike's face: a button, a clock, and the log to read afterwards.
    ///
    /// Start it, lower your wrist, and sit through half an hour without looking.
    /// What it is asking you to notice is which bursts you *felt*; the list is
    /// what the app believed it did, and the two disagreeing is the finding.
    struct DiscreetSpikeView: View {
        let catalogue: TechniqueListModel

        @Environment(WatchSettings.self) private var settings
        @State private var spike = DiscreetSpike()

        /// Coherent breathing, because it is what discreet mode is for: the
        /// gentlest pace in the catalogue and the one whose six breaths come to
        /// about a minute.
        private static let slug = "coherent-breathing"

        var body: some View {
            List {
                Section {
                    control
                    elapsed
                } header: {
                    Text(settings.playsHaptics ? "Haptics on" : "Haptics OFF — turn them on")
                }

                if !spike.log.isEmpty {
                    Section("Log") {
                        ForEach(spike.log) { entry in
                            LabeledContent(
                                entry.what,
                                value: entry.elapsed.formatted(.time(pattern: .minuteSecond))
                            )
                            .font(.caption2)
                        }
                    }
                }
            }
            .navigationTitle("Discreet spike")
        }

        @ViewBuilder
        private var control: some View {
            if spike.isRunning {
                Button("End", role: .destructive) { spike.end() }
            } else if let technique {
                Button("Start 30 min") {
                    spike.start(
                        technique: technique,
                        cues: WatchHapticController(settings: settings)
                    )
                }
            } else {
                Text("Waiting for the catalogue")
                    .font(.caption2)
            }
        }

        private var elapsed: some View {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                LabeledContent(
                    "Elapsed",
                    value: spike.elapsed.formatted(.time(pattern: .minuteSecond))
                )
                .font(.caption2)
            }
        }

        private var technique: Technique? {
            guard case let .loaded(techniques) = catalogue.state else { return nil }
            return techniques.first { $0.slug == Self.slug }
        }
    }
#endif
