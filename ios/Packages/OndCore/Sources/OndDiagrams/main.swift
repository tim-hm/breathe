import Foundation
import OndCatalogue
import OndKit

/// Redraws the marketing site's technique figures from the same geometry the
/// apps draw, and writes them into the committed HTML.
///
/// The site and the app must show a technique as the same shape, and the only
/// way to guarantee that rather than remember it is for both to come out of
/// `TechniqueFigure`. The page has no build step, so this runs at development
/// time and commits its output — `mise run generate:diagrams`, pinned by
/// `mise run check:diagrams`, on the same contract as the generated protobuf.
///
/// It rewrites only the `<svg>` between a slug's markers. The `figcaption`, the
/// tab labels and every word of copy around them stay hand-written, because the
/// page's voice is not derived from anything.
///
/// Usage: `OndDiagrams <catalogue.json> <index.html>`
@main
enum OndDiagrams {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else {
            fail("usage: OndDiagrams <catalogue.json> <index.html>")
        }

        let catalogue = URL(filePath: arguments[1])
        let page = URL(filePath: arguments[2])

        do {
            let techniques = try CatalogueExport.techniques(at: catalogue)
            var html = try String(contentsOf: page, encoding: .utf8)
            var redrawn: [String] = []

            for technique in techniques {
                guard let markers = Markers(slug: technique.slug, in: html) else { continue }
                html.replaceSubrange(markers.between, with: SVG.figure(for: technique))
                redrawn.append(technique.slug)
            }

            // A marker naming a slug the catalogue no longer has is the failure
            // worth shouting about: the page keeps drawing a technique that has
            // been renamed or removed, the figure is never rewritten again, and
            // no diff appears for `check:diagrams` to fail on.
            let orphans = Markers.slugs(in: html).subtracting(redrawn)
            guard orphans.isEmpty else {
                fail(
                    "\(page.path) has generated:figure markers for "
                        + "\(orphans.sorted().joined(separator: ", ")), which the catalogue "
                        + "does not hold — rename the marker or drop the figure"
                )
            }

            guard !redrawn.isEmpty else {
                fail("no generated:figure markers in \(page.path) — nothing to redraw")
            }

            try html.write(to: page, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(
                Data("redrew \(redrawn.count) figures in \(page.lastPathComponent)\n".utf8)
            )
        } catch {
            fail("\(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("OndDiagrams: \(message)\n".utf8))
        exit(1)
    }
}

/// Where one technique's generated figure sits in the page.
///
/// Markers rather than a parsed DOM: the surrounding HTML is hand-written and
/// must survive untouched, and the smallest thing that guarantees that is only
/// ever touching the span between two comments.
private struct Markers {
    let between: Range<String.Index>

    init?(slug: String, in html: String) {
        let opening = "<!-- generated:figure \(slug) -->"
        let closing = "<!-- /generated:figure -->"

        guard let start = html.range(of: opening),
              let end = html.range(of: closing, range: start.upperBound ..< html.endIndex)
        else {
            return nil
        }

        between = start.upperBound ..< end.lowerBound
    }

    /// Every slug the page has an opening marker for, so a marker naming a
    /// technique the catalogue dropped can be reported rather than skipped.
    static func slugs(in html: String) -> Set<String> {
        var slugs: Set<String> = []
        var rest = html[...]

        while let opening = rest.range(of: "<!-- generated:figure ") {
            let after = rest[opening.upperBound...]
            guard let close = after.range(of: " -->") else { break }
            slugs.insert(String(after[..<close.lowerBound]))
            rest = after[close.upperBound...]
        }

        return slugs
    }
}

/// One figure as inline SVG, in the site's own idiom.
private enum SVG {
    /// The site's viewBox, kept from the figures this replaces so the
    /// surrounding CSS and the column width it was tuned against still hold.
    static let box = CGSize(width: 220, height: 170)
    /// Room for the labels, which sit outside the drawing.
    ///
    /// Much wider than it is tall: a side label is pushed clear of the figure
    /// and *then* runs outwards, so the horizontal margin has to hold the push
    /// plus the width of `hold · 4` at 11px — about 42 points — where a label
    /// above or below only costs its own line height.
    static let margin = CGSize(width: 58, height: 24)
    /// How far a label sits from the point it names.
    static let labelOffset = 14.0
    /// The site strokes its figures at 1.5 and its baselines at 1.
    static let lineWidth = 1.5

    /// The indentation the figures sit at in the hand-written page. Matched
    /// rather than inferred: the generator owns only the span between the
    /// markers, and output that did not line up with the HTML either side of it
    /// would make every regeneration look like a reformat.
    static let indent = String(repeating: " ", count: 12)

    static func figure(for technique: Technique) -> String {
        let figures = TechniqueFigure.all(for: technique)
        let inner = indent + "  "
        var lines = [
            "\(indent)<svg",
            "\(inner)viewBox=\"0 0 \(number(box.width)) \(number(box.height))\"",
            "\(inner)width=\"\(number(box.width))\"",
            "\(inner)height=\"\(number(box.height))\"",
            "\(inner)aria-label=\"\(escape(figures.spoken))\"",
            "\(indent)>",
        ]

        // A staged technique draws its figures side by side in one viewBox, the
        // same arrangement the phone's chart uses.
        for (index, figure) in figures.enumerated() {
            let cell = cell(index: index, of: figures.count)
            let transform = figure.transform(into: cell)

            lines += figure.drawable.map { inner + path($0, through: transform) }
            lines += figure.labels.map { inner + text($0, through: transform) }
        }

        lines.append("\(indent)</svg>")
        // Trailing indent so the closing marker lands in the same column as the
        // opening one.
        return "\n" + lines.joined(separator: "\n") + "\n" + indent
    }

    // MARK: Layout

    /// The rect one stage's figure is drawn into, inside the label margin.
    static func cell(index: Int, of count: Int) -> CGRect {
        let content = CGRect(
            x: margin.width,
            y: margin.height,
            width: box.width - margin.width * 2,
            height: box.height - margin.height * 2
        )
        guard count > 1 else { return content }

        let gap = 10.0
        let width = (content.width - gap * Double(count - 1)) / Double(count)
        return CGRect(
            x: content.minX + (width + gap) * Double(index),
            y: content.minY,
            width: width,
            height: content.height
        )
    }

    // MARK: Elements

    static func path(
        _ stroke: TechniqueFigure.Stroke,
        through transform: CGAffineTransform
    ) -> String {
        // The start dot, which the site draws as a <circle> rather than as a
        // path arc. Asked of the stroke rather than inferred from its commands,
        // so the phone's list row and this agree on what the dot is.
        if stroke.role == .start, case let .circle(centre, radius) = stroke.commands[0] {
            let placed = centre.applying(transform)
            let scaled = radius * transform.a
            return """
            <circle cx="\(number(placed.x))" cy="\(number(placed.y))" \
            r="\(number(scaled))" fill="none" stroke-width="\(number(lineWidth))" \
            class="\(className(stroke.ink))" />
            """
        }

        var d: [String] = []
        for command in stroke.commands {
            switch command {
            case let .move(point):
                d.append("M\(pair(point, transform))")
            case let .line(point):
                d.append("L\(pair(point, transform))")
            case let .quadCurve(point, control):
                d.append("Q\(pair(control, transform)) \(pair(point, transform))")
            case let .curve(point, control1, control2):
                d.append(
                    "C\(pair(control1, transform)) \(pair(control2, transform)) \(pair(point, transform))"
                )
            case let .circle(centre, radius):
                // No figure emits a circle alongside other commands today; a
                // silent skip would be a mark that vanished, so say so.
                let placed = centre.applying(transform)
                d.append("M\(number(placed.x - radius * transform.a)) \(number(placed.y))")
            }
        }

        return """
        <path d="\(d.joined(separator: " "))" fill="none" \
        stroke-width="\(number(stroke.role == .baseline ? 1 : lineWidth))" stroke-linecap="round" \
        stroke-linejoin="round"\(stroke.dashed ? " stroke-dasharray=\"4 5\"" : "") \
        class="\(className(stroke.ink))" />
        """
    }

    static func text(
        _ label: TechniqueFigure.Label,
        through transform: CGAffineTransform
    ) -> String {
        let anchor = label.at.applying(transform)
        // Pushed clear of the line it names, along the direction the geometry
        // asked for.
        let placed = CGPoint(
            x: anchor.x + label.away.dx * labelOffset,
            y: anchor.y + label.away.dy * labelOffset
        )

        let alignment = if label.away.dx > 0.4 {
            "start"
        } else if label.away.dx < -0.4 {
            "end"
        } else {
            "middle"
        }

        return """
        <text x="\(number(placed.x))" y="\(number(placed.y))" \
        text-anchor="\(alignment)" dominant-baseline="middle">\(escape(label.text))</text>
        """
    }

    /// The stroke classes `web/style.css` colours. Named for the moment of
    /// breath, like the ink they come from.
    static func className(_ ink: TechniqueFigure.Ink) -> String {
        switch ink {
        case .inhale: "stroke-in"
        case .exhale: "stroke-out"
        case .hold: "stroke-hold"
        case .baseline: "stroke-baseline"
        }
    }

    // MARK: Formatting

    static func pair(_ point: CGPoint, _ transform: CGAffineTransform) -> String {
        let placed = point.applying(transform)
        return "\(number(placed.x)) \(number(placed.y))"
    }

    /// At most two decimals, and no trailing zeros — the committed diff should
    /// be readable, and a coordinate is not meaningful past a hundredth of a
    /// point.
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%g", rounded)
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
