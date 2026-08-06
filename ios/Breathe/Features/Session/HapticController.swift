import BreatheKit
import CoreHaptics
import os
import UIKit

/// The phone breathing with you: one haptic pattern per phase, shaped like the
/// breath it accompanies.
///
/// Lives in the app target rather than `BreatheKit` because CoreHaptics is
/// iOS-only and the watch app in M9 has a different vocabulary entirely
/// (`WKHapticType`, discrete taps). The session engine drives both through
/// `SessionCueing` without knowing which one it has.
@MainActor
final class HapticController {
    private static let logger = Logger(subsystem: "xyz.holmie.breathe", category: "haptics")

    /// Whether the hardware can play a pattern at all. A Haptic Touch-only
    /// device and the simulator both answer no, and both fall back to
    /// `UIImpactFeedbackGenerator` — which cannot express a curve, so the
    /// fallback marks boundaries rather than shaping phases.
    private let supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private var engine: CHHapticEngine?
    private var impacts: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]

    func prepare() {
        guard supportsHaptics else {
            // Prepared up front: the first `impactOccurred` on a cold generator
            // is the one that arrives late, and that is a phase boundary.
            for style in [UIImpactFeedbackGenerator.FeedbackStyle.medium, .soft, .rigid, .light] {
                let generator = UIImpactFeedbackGenerator(style: style)
                generator.prepare()
                impacts[style] = generator
            }
            return
        }

        do {
            let engine = try CHHapticEngine()

            // The engine is reset out from under us by an audio-session
            // interruption or a media-services restart. Without this the rest of
            // the session is silent, with nothing in the UI to say so.
            engine.resetHandler = { [weak self] in
                Task { @MainActor in self?.restart() }
            }
            engine.stoppedHandler = { reason in
                Self.logger.notice("haptic engine stopped: \(reason.rawValue)")
            }

            try engine.start()
            self.engine = engine
        } catch {
            Self.logger.error("haptic engine unavailable: \(error.localizedDescription)")
        }
    }

    func play(_ beat: SessionTimeline.Beat) {
        guard let engine else {
            playFallback(for: beat.kind)
            return
        }

        do {
            let player = try engine.makePlayer(with: pattern(for: beat))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            Self.logger.error("haptic pattern failed: \(error.localizedDescription)")
            playFallback(for: beat.kind)
        }
    }

    /// Three quickening taps — a full stop that feels like one, without asking
    /// the person to look at the screen to know they are done.
    func playCompletion() {
        guard let engine else {
            impacts[.medium]?.impactOccurred()
            return
        }

        do {
            let taps = [0.0, 0.14, 0.28].enumerated().map { index, time in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(
                            parameterID: .hapticIntensity,
                            value: 0.5 + Float(index) * 0.2
                        ),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
                    ],
                    relativeTime: time
                )
            }
            let player = try engine.makePlayer(with: CHHapticPattern(events: taps, parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            Self.logger.error("completion haptic failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        impacts.removeAll()
    }

    private func restart() {
        do {
            try engine?.start()
        } catch {
            Self.logger.error("haptic engine restart failed: \(error.localizedDescription)")
        }
    }

    /// Inhale swells, exhale ebbs, and the two holds are single taps that feel
    /// unalike — the proto keeps `HOLD_IN` and `HOLD_OUT` distinct precisely
    /// because they should not be confusable with your eyes shut.
    private func pattern(for beat: SessionTimeline.Beat) throws -> CHHapticPattern {
        switch beat.kind {
        case .inhale:
            try swell(over: beat.duration, from: 0.12, to: 0.85, sharpness: 0.3)
        case .exhale:
            try swell(over: beat.duration, from: 0.8, to: 0.08, sharpness: 0.1)
        case .holdIn:
            try tap(intensity: 0.9, sharpness: 0.8)
        case .holdOut:
            try tap(intensity: 0.45, sharpness: 0.1)
        }
    }

    /// A continuous event whose intensity is driven across the whole phase by a
    /// parameter curve. The curve multiplies the event's own intensity, which is
    /// why the event is authored at full strength and the shape lives entirely
    /// in the control points.
    private func swell(
        over duration: Duration,
        from start: Float,
        to end: Float,
        sharpness: Float
    ) throws -> CHHapticPattern {
        let seconds = duration.seconds
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0,
            duration: seconds
        )

        let curve = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [
                CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: start),
                CHHapticParameterCurve.ControlPoint(relativeTime: seconds, value: end),
            ],
            relativeTime: 0
        )

        return try CHHapticPattern(events: [event], parameterCurves: [curve])
    }

    private func tap(intensity: Float, sharpness: Float) throws -> CHHapticPattern {
        try CHHapticPattern(
            events: [
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                    ],
                    relativeTime: 0
                ),
            ],
            parameters: []
        )
    }

    /// The four styles carry as much of the distinction as this API can: the
    /// breaths differ from each other, and both holds differ from both breaths.
    private func playFallback(for kind: PhaseKind) {
        let style: UIImpactFeedbackGenerator.FeedbackStyle = switch kind {
        case .inhale: .medium
        case .exhale: .soft
        case .holdIn: .rigid
        case .holdOut: .light
        }

        impacts[style]?.impactOccurred()
        impacts[style]?.prepare()
    }
}
