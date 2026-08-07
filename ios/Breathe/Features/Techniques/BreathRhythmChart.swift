import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// The exercise's rhythm as a closed loop — one cycle, drawn from the same
/// dialled values the session will play. Because it reads the dialled exercise,
/// it redraws live as the Customise dials move, which is half the point: the
/// loop visibly squares up as the holds lengthen.
///
/// The list row draws the same loop at row size through `BreathRhythmMark`.
/// Both stand on `BreathLoop`, `RhythmGeometry` and `RhythmInk`, so an exercise
/// is the same shape in the same colours wherever it appears; what this one
/// adds is the repeat counts, the nostril hints, the mark for where the breath
/// starts, and the key.
struct BreathRhythmChart: View {
    /// The dialled exercise, not the curated one — the chart is a preview of
    /// the session the Begin button starts.
    let technique: Technique

    private static let lineWidth: CGFloat = 2.5
    /// A single loop is the figure on the screen and gets the room for it. A
    /// staged exercise draws one per stage, small enough that three of them and
    /// their gaps still fit the narrowest phone.
    private static let side: CGFloat = 150
    private static let stagedSide: CGFloat = 84

    var body: some View {
        let loops = technique.loops
        let accent = technique.goal.accent
        let hints = PhaseHints.hints(for: technique)
        let side = loops.count > 1 ? Self.stagedSide : Self.side

        VStack(spacing: Theme.Spacing.standard) {
            HStack(alignment: .top, spacing: Theme.Spacing.standard) {
                ForEach(Array(loops.enumerated()), id: \.offset) { index, loop in
                    VStack(spacing: Theme.Spacing.tight) {
                        figure(
                            of: loop,
                            accent: accent,
                            hints: hints?.indices.contains(index) == true ? hints?[index] : nil,
                            side: side
                        )
                        repeatCaption(of: loop)
                    }
                }
            }
            .frame(maxWidth: .infinity)

            key(of: loops, accent: accent)
        }
        // The key below names the colours, and the phase capsules further down
        // say the same thing as text, so VoiceOver gets a description rather
        // than a picture of one.
        .accessibilityHidden(true)
    }

    private func figure(
        of loop: BreathLoop,
        accent: Color,
        hints: [String?]?,
        side: CGFloat
    ) -> some View {
        let size = CGSize(width: side, height: side)
        let inset = Self.lineWidth / 2

        return ZStack {
            RhythmGeometry.outline(of: loop, in: size, inset: inset)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.16), accent.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            ForEach(Array(loop.arcs.enumerated()), id: \.offset) { _, arc in
                RhythmGeometry.line(of: loop, from: arc.start, to: arc.end, in: size, inset: inset)
                    .stroke(
                        RhythmInk(arc.kind).colour(on: accent),
                        style: StrokeStyle(
                            lineWidth: Self.lineWidth,
                            lineCap: .round,
                            // Dashing is a separate axis from colour: it marks
                            // an open-ended stage, whose durations describe a
                            // typical pass rather than a scheduled one.
                            dash: arc.dashed ? [4, 5] : []
                        )
                    )
            }

            start(of: loop, accent: accent, in: size, inset: inset)
            hintLabels(of: loop, hints: hints, accent: accent, in: size)
        }
        .frame(width: side, height: side)
    }

    /// A dot where the loop begins, at empty lungs.
    ///
    /// A closed line has no beginning to find and no direction to read; the
    /// colours only resolve it once you already know the loop runs clockwise.
    /// This is the one mark that says where to put your finger.
    private func start(
        of loop: BreathLoop,
        accent: Color,
        in size: CGSize,
        inset: CGFloat
    ) -> some View {
        Circle()
            .fill(RhythmInk.rising.colour(on: accent))
            .frame(width: Self.lineWidth * 2.4, height: Self.lineWidth * 2.4)
            .position(RhythmGeometry.place(loop.point(at: 0), in: size, inset: inset))
    }

    /// "×30" under a stage that repeats. Only where there is one — a cyclic
    /// exercise's repeat count is already the headline of the length control.
    @ViewBuilder
    private func repeatCaption(of loop: BreathLoop) -> some View {
        if loop.cycles > 1, technique.isStaged {
            Text("×\(loop.cycles)")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }

    /// "L", "R" beside alternate-nostril's breaths — the switching pattern at a
    /// glance, before the session spells it out. Initials rather than words,
    /// and inside the loop, which is empty and has the room.
    @ViewBuilder
    private func hintLabels(
        of loop: BreathLoop,
        hints: [String?]?,
        accent: Color,
        in size: CGSize
    ) -> some View {
        // All labels or none: the counts match today because the loop draws one
        // arc per phase, but that is a drawing judgement, not a contract — and
        // a silently truncating zip would mislabel the chart the day it
        // changes.
        if let hints, hints.count == loop.arcs.count {
            ForEach(Array(zip(loop.arcs, hints).enumerated()), id: \.offset) { _, pair in
                let (arc, hint) = pair
                if let hint {
                    Text(hint.prefix(1))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(accent)
                        .position(
                            inward(
                                from: loop.point(at: (arc.start + arc.end) / 2),
                                in: size,
                                by: 14
                            )
                        )
                }
            }
        }
    }

    /// A point on the loop, pulled towards the middle so a label sits beside
    /// its arc rather than on top of it.
    private func inward(from point: CGPoint, in size: CGSize, by distance: CGFloat) -> CGPoint {
        let placed = RhythmGeometry.place(point, in: size, inset: 0)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = max(hypot(placed.x - centre.x, placed.y - centre.y), 0.001)
        return CGPoint(
            x: placed.x + (centre.x - placed.x) / reach * distance,
            y: placed.y + (centre.y - placed.y) / reach * distance
        )
    }

    /// What the colours mean, in three words or fewer.
    ///
    /// The direction of travel says it too, but only once you know to look; a
    /// dash of each colour beside its word is what makes the first glance
    /// legible. Deliberately not repeated in the list row, where there is no
    /// room and nothing to decide.
    ///
    /// Centred under the figure rather than aligned with the prose either side
    /// of it: it captions the drawing, and a key hard against the left margin
    /// of a centred loop reads as belonging to neither.
    private func key(of loops: [BreathLoop], accent: Color) -> some View {
        HStack(spacing: Theme.Spacing.standard) {
            ForEach(RhythmInk.present(in: loops), id: \.self) { ink in
                HStack(spacing: Theme.Spacing.tight) {
                    Capsule()
                        .fill(ink.colour(on: accent))
                        .frame(width: 12, height: 3)
                    Text(ink.word)
                        .font(.caption2)
                        .foregroundStyle(Theme.Ink.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
