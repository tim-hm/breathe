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

    public func load() async {
        state = .loading
        do {
            state = try await .loaded(topics.listFoundations())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
