import OndKit
import OndStyle
import OndUI
import SwiftUI

/// The exercise's shape, drawn from the same dialled values the session will
/// play. Because it reads the dialled exercise it redraws live as the Customise
/// dials move, which is half the point: box breathing's square visibly stretches
/// as one side is lengthened.
///
/// The list row draws the same figure at row size through `BreathRhythmMark`.
/// Both stand on `TechniqueFigure`, so an exercise is the same shape in the same
/// colours wherever it appears — including the marketing site, whose figures are
/// generated from it. What this one adds is the labels, the repeat counts, and
/// the description a screen reader hears.
struct BreathRhythmChart: View {
    /// The dialled exercise, not the curated one — the chart is a preview of the
    /// session the Begin button starts.
    let technique: Technique

    private static let lineWidth: CGFloat = 2.5
    /// A single figure is the thing on the screen and gets the room for it. A
    /// staged exercise draws one per stage, small enough that three of them and
    /// their gaps still fit the narrowest phone.
    private static let side: CGFloat = 168
    private static let stagedSide: CGFloat = 92
    /// The gutters the labels live in, *outside* the drawing rather than inset
    /// into it — a figure that gave up a quarter of its width to the words
    /// naming it would be a caption with a diagram attached. Wider than it is
    /// tall because `hold · 4` beside a side costs its whole width, where the
    /// same words above cost one line.
    private static let labelGutter = CGSize(width: 48, height: 24)
    /// The gap between a line and the nearest edge of the label naming it.
    private static let labelGap: CGFloat = 6

    /// Each label's measured size, so it can be pushed clear of the figure by
    /// its own half-width rather than by a guess.
    @State private var labelSizes: [Int: CGSize] = [:]

    var body: some View {
        let figures = TechniqueFigure.all(for: technique)
        let accent = technique.goal.accent
        let side = figures.count > 1 ? Self.stagedSide : Self.side

        HStack(alignment: .top, spacing: Theme.Spacing.standard) {
            ForEach(Array(figures.enumerated()), id: \.offset) { _, figure in
                VStack(spacing: Theme.Spacing.tight) {
                    drawing(of: figure, accent: accent, side: side)
                    repeatCaption(of: figure)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // One element carrying the whole cycle in words. The figure's own labels
        // say it on screen; this is the same sentence for somebody who is not
        // looking at it, and since the phase capsules that used to carry these
        // facts are gone, it is the only place they exist for VoiceOver.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(figures.spoken)
    }

    private func drawing(of figure: TechniqueFigure, accent: Color, side: CGFloat) -> some View {
        let bounds = figure.bounds
        // The gutters exist only where there are labels to put in them.
        let gutter = figure.labels.isEmpty ? .zero : Self.labelGutter

        return ZStack {
            ZStack {
                FigureShape(commands: figure.fill, bounds: bounds, lineWidth: Self.lineWidth)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.16), accent.opacity(0.03)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                ForEach(Array(figure.drawable.enumerated()), id: \.offset) { _, stroke in
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
                            lineJoin: .round,
                            // Dashing is a separate axis from colour: it
                            // marks an open-ended stage, whose durations
                            // describe a typical pass rather than a
                            // scheduled one.
                            dash: stroke.dashed ? TechniqueFigure.Stroke.dash : []
                        )
                    )
                }
            }
            .frame(width: side, height: side)

            labels(of: figure, side: side, gutter: gutter)
        }
        .frame(width: side + gutter.width * 2, height: side + gutter.height * 2)
    }

    /// `in · 4` beside the side it belongs to — the marketing site's treatment,
    /// and what let the colour key that used to sit under this chart go. A
    /// reader who has to look up a legend is reading the picture twice.
    ///
    /// Each label is offset by half its own measured size in the direction it
    /// points, so its near *edge* clears the line rather than its centre. Placed
    /// by centre alone, `in · 4` reads as sitting on the inhale side rather than
    /// beside it — the text is wider than the gap it was given.
    private func labels(of figure: TechniqueFigure, side: CGFloat, gutter: CGSize) -> some View {
        // Anchors are computed in the drawing's own frame and then shifted by
        // the gutter, because the drawing sits centred inside this larger one.
        let drawn = CGRect(x: 0, y: 0, width: side, height: side)
        let transform = figure.transform(into: drawn, lineWidth: Self.lineWidth)

        return ForEach(Array(figure.labels.enumerated()), id: \.offset) { index, label in
            let anchor = label.at.applying(transform)
            let size = labelSizes[index] ?? .zero

            Text(label.text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.Ink.secondary)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { labelSizes[index] = $0 }
                .position(
                    x: gutter.width + anchor.x
                        + label.away.dx * (Self.labelGap + size.width / 2),
                    y: gutter.height + anchor.y
                        + label.away.dy * (Self.labelGap + size.height / 2)
                )
        }
    }

    /// `×30` under a stage that repeats. Only where there is one — a cyclic
    /// exercise's repeat count is already the headline of the length control.
    @ViewBuilder
    private func repeatCaption(of figure: TechniqueFigure) -> some View {
        if figure.cycles > 1, technique.isStaged {
            Text("×\(figure.cycles)")
                .font(.caption2)
                .foregroundStyle(Theme.Ink.tertiary)
        }
    }
}
