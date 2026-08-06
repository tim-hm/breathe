import BreatheKit
import Foundation

@MainActor
@Observable
final class TechniqueListModel {
    /// The states the list can be in. An enum rather than parallel
    /// `isLoading`/`error`/`techniques` properties, because those admit
    /// combinations that mean nothing — loading *and* failed, say — and every
    /// view then has to decide which one wins.
    enum State {
        case loading
        case loaded([Technique])
        case failed(String)
    }

    private(set) var state: State = .loading

    private let techniques: any TechniqueReading

    init(techniques: any TechniqueReading) {
        self.techniques = techniques
    }

    func load() async {
        state = .loading
        do {
            state = try await .loaded(techniques.listTechniques())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
