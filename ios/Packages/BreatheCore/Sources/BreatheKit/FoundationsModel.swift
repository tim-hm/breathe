import Foundation
import Observation

/// Drives the foundations screen: one `State`, mutated only by `load()`.
///
/// The same shape as `TechniqueListModel`, and for the same reason — the states
/// are exclusive, and parallel `isLoading`/`error` properties would admit
/// combinations that mean nothing.
@MainActor
@Observable
public final class FoundationsModel {
    public enum State {
        case loading
        case loaded([FoundationTopic])
        case failed(String)
    }

    public private(set) var state: State = .loading

    private let topics: any TechniqueReading

    public init(topics: any TechniqueReading) {
        self.topics = topics
    }

    /// Loads unless the topics are already here.
    ///
    /// The screen is pushed and popped, and its `.task` runs every time; the
    /// foundations are immutable seeded reference data, so a second visit has
    /// nothing to fetch and reloading would only replace a good answer with a
    /// spinner. The catalogue's model has no equivalent because its screen is
    /// the stack root and appears once.
    public func loadIfNeeded() async {
        if case .loaded = state {
            return
        }
        await load()
    }

    public func load() async {
        state = .loading
        do {
            state = try await .loaded(topics.listFoundations())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
