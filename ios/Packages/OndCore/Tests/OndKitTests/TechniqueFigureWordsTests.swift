import CoreGraphics
import Foundation
import OndKit
import Testing

/// What a figure says about itself — the words on it, and the sentence a
/// screen reader hears in place of it.
///
/// A suite of its own rather than a section of `TechniqueFigureTests`: the
/// geometry there is about shape, and this is about language. They share only
/// the fixtures, which is what `SeededCatalogue` is for.
@Suite("What a figure says")
struct TechniqueFigureWordsTests {
    /// The silhouette a technique draws, rounded to a thousandth so a
    /// floating-point wobble is never mistaken for a different picture.
    private func silhouette(of technique: Technique) -> String {
        TechniqueFigure.all(for: technique)
            .flatMap(SeededCatalogue.points(of:))
            .map { "\(($0.x * 1000).rounded()),\(($0.y * 1000).rounded())" }
            .joined(separator: " ")
    }

    /// Nine techniques, eight silhouettes — and the one collision is the honest
    /// kind. Box and long box are the same ratios at different lengths, so one
    /// shape is what they *are*. The grammar this replaced collided five of them
    /// on nothing more than "neither of us holds", which is not the same claim.
    @Test("No two techniques share a silhouette, except the two that share ratios")
    func silhouettesAreDistinct() {
        var seen: [String: String] = [:]

        for technique in SeededCatalogue.techniques {
            let drawn = silhouette(of: technique)
            if let other = seen[drawn] {
                #expect(
                    Set([technique.slug, other]) == ["box-breathing", "long-box-breathing"],
                    "`\(technique.slug)` draws the same as `\(other)`"
                )
            }
            seen[drawn] = technique.slug
        }
    }

    /// The claim that matters on screen: whatever the silhouettes do, no two
    /// techniques are the same drawing once their labels are on them.
    @Test("Every seeded technique draws something no other technique draws")
    func everyTechniqueIsDistinct() {
        var seen: [String: String] = [:]

        for technique in SeededCatalogue.techniques {
            let labels = TechniqueFigure.all(for: technique)
                .flatMap(\.labels)
                .map(\.text)
                .joined(separator: " ")
            let drawn = "\(silhouette(of: technique)) \(labels)"

            #expect(
                seen[drawn] == nil,
                "`\(technique.slug)` draws the same as `\(seen[drawn] ?? "")`"
            )
            seen[drawn] = technique.slug
        }
    }

    /// Every figure has to fit the box it is handed, whatever the durations.
    @Test("Every seeded technique stays inside its frame")
    func everyFigureFitsItsFrame() {
        for technique in SeededCatalogue.techniques {
            for drawn in TechniqueFigure.all(for: technique) {
                for point in SeededCatalogue.points(of: drawn) {
                    #expect(point.x >= -0.001 && point.x <= 1.001, "`\(technique.slug)`")
                    #expect(point.y >= -0.001 && point.y <= 1.001, "`\(technique.slug)`")
                }
            }
        }
    }

    /// The chart is hidden from VoiceOver and the row of phase capsules that
    /// used to carry these facts as text is gone, so this string is now the only
    /// thing a screen reader has. It is also the generated SVG's `aria-label`,
    /// which is what makes the page and the app describe a technique alike.
    @Test("The description names every phase, in order, with its length")
    func describesEveryPhase() {
        let description = SeededCatalogue.figure("box-breathing").description

        #expect(description == """
        One cycle: Breathe in for 4 seconds, Hold, lungs full for 4 seconds, \
        Breathe out for 4 seconds, Hold, lungs empty for 4 seconds. Repeated 8 times.
        """)
    }

    /// Bellows breath is the one exercise whose phases last exactly a second,
    /// so it is the one that says "1 seconds" if the length is glued to a bare
    /// plural. Somebody using a screen reader hears every one of these.
    @Test("A one-second phase is spoken in the singular")
    func describesASingleSecond() {
        let description = SeededCatalogue.figure("bellows-breath").description

        #expect(description.contains("for 1 second,"))
        #expect(!description.contains("1 seconds"))
    }

    /// A nostril hint is a fact the phase kind cannot carry, and somebody
    /// listening rather than looking needs it most.
    @Test("The description carries the nostril where there is one")
    func describesNostrils() {
        let description = SeededCatalogue.figure("alternate-nostril").description

        #expect(description.contains("Breathe in, left nostril"))
        #expect(description.contains("Breathe out, right nostril"))
    }

    /// An open-ended hold has no number to state, and stating the seeded one
    /// would promise a length the session does not keep.
    @Test("The retention is described as the person's to end")
    func describesTheRetention() {
        let description = SeededCatalogue
            .figure("wim-hof-rounds", stage: SeededCatalogue.retention)
            .description

        #expect(description.contains("as long as you can"))
        #expect(!description.contains("60 seconds"))
    }
}
