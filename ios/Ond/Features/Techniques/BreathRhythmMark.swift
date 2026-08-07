import OndKit
import OndStyle
import OndUI
import SwiftUI

/// An exercise's rhythm at row size: the same loop the detail screen draws,
/// reduced to the line and its wash.
///
/// A miniature rather than a second drawing. What it drops — the repeat counts,
/// the nostril hints, the starting dot, the key — is everything that needs
/// reading; what it keeps is the silhouette and the two halves of the breath,
/// which are what tell one exercise from another at a glance down a list.
///
/// It draws the curated exercise, not a dialled one: a row is a portrait of
/// what the catalogue offers, and the person's own settings belong on the
/// screen where they were made.
struct BreathRhythmMark: View {
    let technique: Technique

    private static let lineWidth: CGFloat = 1.6
    static let side: CGFloat = 38

    var body: some View {
        let accent = technique.goal.accent
        let size = CGSize(width: Self.side, height: Self.side)
        let inset = Self.lineWidth / 2

        HStack(spacing: Theme.Spacing.tight) {
            ForEach(Array(technique.loops.enumerated()), id: \.offset) { _, loop in
                ZStack {
                    RhythmGeometry.outline(of: loop, in: size, inset: inset)
                        .fill(
                            LinearGradient(
                                colors: [accent.opacity(0.18), accent.opacity(0.03)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    ForEach(Array(loop.arcs.enumerated()), id: \.offset) { _, arc in
                        RhythmGeometry
                            .line(of: loop, from: arc.start, to: arc.end, in: size, inset: inset)
                            .stroke(
                                RhythmInk(arc.kind).colour(on: accent),
                                style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round)
                            )
                    }
                }
                .frame(width: Self.side, height: Self.side)
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
