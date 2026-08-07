import BreatheKit
import BreatheStyle
import BreatheUI
import SwiftUI

/// An exercise's rhythm at row size: the same curve the detail screen draws,
/// reduced to the line and its wash.
///
/// A miniature rather than a second drawing. What it drops — the stage
/// dividers, the repeat counts, the nostril hints, the key — is everything that
/// needs reading; what it keeps is the shape and the two halves of the breath,
/// which are what tell one exercise from another at a glance down a list.
///
/// It draws the curated exercise, not a dialled one: a row is a portrait of
/// what the catalogue offers, and the person's own settings belong on the
/// screen where they were made.
struct BreathRhythmMark: View {
    let technique: Technique

    private static let lineWidth: CGFloat = 1.6

    var body: some View {
        let rhythm = BreathRhythm(technique: technique)
        let accent = technique.goal.accent

        GeometryReader { geometry in
            let size = geometry.size

            RhythmGeometry.area(rhythm, in: size, inset: Self.lineWidth)
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.18), accent.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            ForEach(RhythmInk.allCases, id: \.self) { ink in
                RhythmGeometry.line(rhythm, in: size, inset: Self.lineWidth) { segment in
                    RhythmInk(segment.kind) == ink
                }
                .stroke(
                    ink.colour(on: accent),
                    style: StrokeStyle(
                        lineWidth: Self.lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        // Undashed even where the chart dashes: a 4pt dash at this size is a
        // line with holes in it rather than a signal, and the row makes no
        // promise about duration for it to qualify.
        //
        // Decoration: the row's name, summary, and shape line carry the facts,
        // and VoiceOver reads them as one element without this in the way.
        .accessibilityHidden(true)
    }
}
