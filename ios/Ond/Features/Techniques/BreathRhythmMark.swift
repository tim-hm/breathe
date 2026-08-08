import OndKit
import OndStyle
import OndUI
import SwiftUI

/// An exercise's shape at row size: the same figure the detail screen draws,
/// reduced to the line and its wash.
///
/// A miniature rather than a second drawing. What it drops — the labels, the
/// repeat counts, the start dot — is everything that needs reading; what it
/// keeps is the silhouette and the two halves of the breath, which are what tell
/// one exercise from another at a glance down a list. That only works because
/// the silhouettes now differ: under the grammar this replaced, five of the nine
/// seeded techniques drew the same circle at this size.
///
/// It draws the curated exercise, not a dialled one: a row is a portrait of what
/// the catalogue offers, and the person's own settings belong on the screen
/// where they were made.
struct BreathRhythmMark: View {
    let technique: Technique

    private static let lineWidth: CGFloat = 1.6
    static let side: CGFloat = 38

    var body: some View {
        let accent = technique.goal.accent
        let figures = TechniqueFigure.all(for: technique)

        HStack(spacing: Theme.Spacing.tight) {
            ForEach(Array(figures.enumerated()), id: \.offset) { _, figure in
                let bounds = figure.bounds

                ZStack {
                    FigureShape(
                        commands: figure.fill,
                        bounds: bounds,
                        lineWidth: Self.lineWidth
                    )
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.18), accent.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    ForEach(Array(strokes(of: figure).enumerated()), id: \.offset) { _, stroke in
                        FigureShape(
                            commands: stroke.commands,
                            bounds: bounds,
                            lineWidth: Self.lineWidth
                        )
                        .stroke(
                            stroke.ink.colour(on: accent),
                            style: StrokeStyle(
                                lineWidth: stroke.weight(on: Self.lineWidth),
                                lineCap: .round,
                                lineJoin: .round
                            )
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
        // Decoration: the row's name and summary carry the facts, and VoiceOver
        // reads them as one element without this in the way.
        .accessibilityHidden(true)
    }

    /// The figure without its start dot. At 38 points the dot is a blob on the
    /// line rather than a mark on it, and a row has no direction to resolve —
    /// nobody traces a list.
    private func strokes(of figure: TechniqueFigure) -> [TechniqueFigure.Stroke] {
        figure.drawable.filter { $0.role != .start }
    }
}
