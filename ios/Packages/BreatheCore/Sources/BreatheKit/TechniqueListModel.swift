import Foundation
import Observation

/// Drives the technique list screen: one `State`, mutated only by `load()`.
///
/// Lives in `BreatheKit` rather than the app target so the state machine is
/// testable on the host — the app target has no test bundle, and package tests
/// can only reach code inside a package target.
@MainActor
@Observable
public final class TechniqueListModel {
    /// The states the list can be in. An enum rather than parallel
    /// `isLoading`/`error`/`techniques` properties, because those admit
    /// combinations that mean nothing — loading *and* failed, say — and every
    /// view then has to decide which one wins.
    public enum State {
        case loading
        case loaded([Technique])
        case failed(String)
    }

    public private(set) var state: State = .loading

    private let techniques: any TechniqueReading

    public init(techniques: any TechniqueReading) {
        self.techniques = techniques
    }

    public func load() async {
        state = .loading
        do {
            state = try await .loaded(techniques.listTechniques())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
