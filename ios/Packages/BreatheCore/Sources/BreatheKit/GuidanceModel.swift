import Foundation
import Observation

/// Drives the "where to start" strip.
///
/// One `State`, mutated only by `load()` — the same shape as
/// `TechniqueListModel` and `FoundationsModel`, and for the same reason:
/// parallel `isLoading`/data properties admit combinations that mean nothing,
/// like a spinner shown over an answer that already arrived.
///
/// What it does not have is a `failed` case, and that is the design. The server
/// answers from its own rules whenever the assistant is unreachable, so the only
/// thing left to fail is the network — and a person opening the techniques tab
/// on a train should see the catalogue, not an error about a suggestion they did
/// not ask for. `unavailable` renders as nothing at all.
@MainActor
@Observable
public final class GuidanceModel {
    public enum State: Sendable {
        case loading
        case loaded(Guidance)
        case unavailable
    }

    public private(set) var state: State = .loading

    private let assistant: any AssistantReading

    public init(assistant: any AssistantReading) {
        self.assistant = assistant
    }

    /// Loads unless an answer is already here.
    ///
    /// The screen's `.task` runs on every arrival; guidance changes when the
    /// profile does, which is rarely, and re-asking on every tab switch would
    /// spend the daily allowance on a screen somebody is scrolling past. A
    /// previous attempt that came back `unavailable` is not retried either —
    /// the network did not recover because a tab was tapped.
    public func loadIfNeeded() async {
        guard case .loading = state else { return }
        await load()
    }

    private func load() async {
        // Quietly. The failure is invisible on purpose: everything this view
        // sits above works without it.
        state = if let guidance = try? await assistant.recommendations() {
            .loaded(guidance)
        } else {
            .unavailable
        }
    }
}
