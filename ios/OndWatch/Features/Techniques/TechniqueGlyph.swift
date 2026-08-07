import OndKit
import OndStyle
import OndUI
import SwiftUI

/// A technique's identity, filling the top of its carousel page: its own figure,
/// in the technique's goal accent.
///
/// It replaced first a coloured disc — which told you nothing, since every
/// technique got the same circle — then a computed fullness curve, which drew
/// them all in one grammar and so made box breathing and 4-7-8 near
/// indistinguishable, and then a table of hand-placed drawings ported from the
/// marketing site. The table went when the site started being generated from
/// `TechniqueFigure` instead: it existed because the site was the reference, and
/// once the arrow points the other way a port is just a copy waiting to go
/// stale.
///
/// Undecorated on purpose. `TechniqueFigure` offers labels and the phone writes
/// them onto the figure, but `in · 4` at wrist size is a smudge and the page
/// beneath already carries the counts as text.
struct TechniqueGlyph: View {
    let technique: Technique
    /// Heavier than the phone's row weight: this drawing carries a whole watch
    /// page, where the phone's carries a list row.
    var lineWidth: CGFloat = 2.5

    var body: some View {
        let accent = technique.goal.accent
        let figures = TechniqueFigure.all(for: technique)

        HStack(spacing: 2) {
            ForEach(Array(figures.enumerated()), id: \.offset) { _, figure in
                let bounds = figure.bounds

                ZStack {
                    ForEach(Array(figure.drawable.enumerated()), id: \.offset) { _, stroke in
                        FigureShape(commands: stroke.commands, bounds: bounds, lineWidth: lineWidth)
                            .stroke(
                                stroke.ink.colour(on: accent),
                                style: StrokeStyle(
                                    lineWidth: stroke.weight(on: lineWidth),
                                    lineCap: .round,
                                    lineJoin: .round
                                )
                            )
                    }
                }
            }
        }
        // Decoration. The name and duration beneath carry the facts, and a shape
        // is not something VoiceOver can usefully describe.
        .accessibilityHidden(true)
    }
}
