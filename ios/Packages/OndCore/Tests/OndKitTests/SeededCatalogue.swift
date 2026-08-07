import Foundation
import OndCatalogue
import OndKit

/// The nine techniques the database is actually seeded with, read from the
/// committed `catalogue.json` at the repo root.
///
/// The figures are drawn from the catalogue's own numbers, so a test that built
/// its own stages would be a claim about a fixture that happens to resemble the
/// catalogue. "Coherent breathing and bellows breath must not draw the same
/// picture" is only worth asserting about the real ones — and when somebody
/// reseeds a technique with different durations, this is what should notice.
///
/// Reads the file `OndDiagrams` reads rather than a copy in the test bundle. A
/// second copy is free to go stale, which is the whole thing
/// `mise run check:generated` exists to prevent.
enum SeededCatalogue {
    static let techniques: [Technique] = {
        do {
            return try CatalogueExport.techniques(at: url)
        } catch {
            fatalError("could not read \(url.path): \(error)")
        }
    }()

    /// The one technique a test names directly. Everything else is looked up by
    /// the shape of its stages, so the catalogue can grow without touching them.
    static func technique(_ slug: String) -> Technique {
        guard let technique = techniques.first(where: { $0.slug == slug }) else {
            fatalError("`\(slug)` is not in the seeded catalogue")
        }
        return technique
    }

    /// One stage's figure, drawn from the seeded technique.
    static func figure(_ slug: String, stage: Int = 0) -> TechniqueFigure {
        TechniqueFigure.all(for: technique(slug))[stage]
    }

    /// Every point a figure's strokes pass through, for measuring a silhouette
    /// without caring which command drew it. The baseline is left out: it is
    /// reference rather than subject, and it spans the full width whatever the
    /// line inside it does.
    static func points(of figure: TechniqueFigure) -> [CGPoint] {
        figure.strokes.filter { $0.role != .baseline }.flatMap { stroke in
            stroke.commands.compactMap { command in
                switch command {
                case let .move(point), let .line(point): point
                case let .quadCurve(point, _): point
                case let .curve(point, _, _): point
                case .circle: nil
                }
            }
        }
    }

    /// Found by walking up from this file rather than by counting directories
    /// to the repo root — a count is silently wrong the day the package moves,
    /// and this reports a missing file rather than a wrong path.
    private static var url: URL {
        var directory = URL(filePath: #filePath).deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory.appending(path: "catalogue.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }

        fatalError("no catalogue.json above \(#filePath) — run `mise run generate:catalogue`")
    }
}
