import Foundation
import OndKit

/// The committed `catalogue.json` — the seeded technique catalogue, exported
/// from `crates/migrate` by `mise run generate:catalogue`.
///
/// The catalogue lives in Rust and the geometry that draws it lives here, so
/// something has to cross between the two languages. This crosses it once, into
/// an artefact `mise run check:generated` pins the export of, rather than once
/// per consumer:
/// the generator that redraws the marketing site reads it, and so do the tests
/// that assert every technique draws a distinct figure — which is only a claim
/// worth making about the techniques the database actually holds.
///
/// Not the app's own path to a catalogue, and in its own target so that stays
/// true: the app fetches one over gRPC and caches it, and `Technique`'s
/// `Codable` conformance round-trips *that*. This decodes the Rust seed's field
/// names, which is a second decoding path onto `Technique` that no shipping
/// binary should be able to reach — so, like `OndAPI`, this is a target and not
/// a product, and neither app can name the module at all.
public enum CatalogueExport {
    /// The techniques in the export at `url`, in presentation order.
    public static func techniques(at url: URL) throws -> [Technique] {
        let export = try JSONDecoder().decode(Export.self, from: Data(contentsOf: url))
        return try export.techniques.map(Technique.init(exported:))
    }

    /// What the export can be wrong about, as opposed to what `JSONDecoder`
    /// already catches.
    public enum Failure: Error, CustomStringConvertible {
        case unknownGoal(String)
        case unknownPhaseKind(String)

        public var description: String {
            switch self {
            case let .unknownGoal(value):
                "`\(value)` is not a goal this app knows"
            case let .unknownPhaseKind(value):
                "`\(value)` is not a phase kind this app knows"
            }
        }
    }

    fileprivate struct Export: Decodable {
        let techniques: [ExportedTechnique]
    }

    fileprivate struct ExportedTechnique: Decodable {
        let slug: String
        let name: String
        let summary: String
        let safetyNote: String
        let goal: String
        let stages: [ExportedStage]
        let recommendedRounds: Int
        let requiresSubscription: Bool
    }

    fileprivate struct ExportedStage: Decodable {
        let phases: [ExportedPhase]
        let cycles: Int
        let openEnded: Bool
    }

    fileprivate struct ExportedPhase: Decodable {
        let kind: String
        let durationMs: Int
        let minDurationMs: Int
        let maxDurationMs: Int
    }
}

private extension Technique {
    init(exported: CatalogueExport.ExportedTechnique) throws {
        try self.init(
            id: exported.slug,
            slug: exported.slug,
            name: exported.name,
            summary: exported.summary,
            goal: TechniqueGoal(exported: exported.goal),
            stages: exported.stages.map(Stage.init(exported:)),
            recommendedRounds: exported.recommendedRounds,
            safetyNote: exported.safetyNote.isEmpty ? nil : exported.safetyNote,
            requires: exported.requiresSubscription ? .plus : .free
        )
    }
}

private extension Stage {
    init(exported: CatalogueExport.ExportedStage) throws {
        try self.init(
            phases: exported.phases.map(Phase.init(exported:)),
            cycles: exported.cycles,
            openEnded: exported.openEnded
        )
    }
}

private extension Phase {
    init(exported: CatalogueExport.ExportedPhase) throws {
        try self.init(
            kind: PhaseKind(exported: exported.kind),
            duration: .milliseconds(exported.durationMs),
            range: .milliseconds(exported.minDurationMs) ... .milliseconds(exported.maxDurationMs)
        )
    }
}

private extension TechniqueGoal {
    /// The export speaks the contract's vocabulary — the Postgres enum's labels
    /// — which is deliberately not this type's raw value.
    init(exported: String) throws {
        switch exported {
        case "CALM": self = .calm
        case "SLEEP": self = .sleep
        case "ENERGY": self = .energy
        case "RESET": self = .reset
        case "FOCUS": self = .focus
        default: throw CatalogueExport.Failure.unknownGoal(exported)
        }
    }
}

private extension PhaseKind {
    init(exported: String) throws {
        switch exported {
        case "INHALE": self = .inhale
        case "HOLD_IN": self = .holdIn
        case "EXHALE": self = .exhale
        case "HOLD_OUT": self = .holdOut
        default: throw CatalogueExport.Failure.unknownPhaseKind(exported)
        }
    }
}
