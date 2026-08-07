import Foundation
import Observation

/// Drives the "what should I do next" strip.
///
/// There is no failure state, and that is the design. The server answers from
/// its own rules whenever the assistant cannot be reached, so the only thing
/// left to fail is the network — and a person opening the techniques tab on a
/// train should see the catalogue, not an error about a suggestion they did not
/// ask for. An unreachable server leaves `guidance` nil and the strip simply
/// does not appear.
@MainActor
@Observable
public final class GuidanceModel {
    /// Nil until an answer arrives, and nil forever if none does.
    public private(set) var guidance: Guidance?

    /// True only while the first load is in flight, so the strip can hold its
    /// height instead of appearing under the reader's thumb.
    public private(set) var isLoading = false

    private let assistant: any AssistantReading

    public init(assistant: any AssistantReading) {
        self.assistant = assistant
    }

    /// Loads unless an answer is already here.
    ///
    /// The screen's `.task` runs on every arrival; guidance changes when the
    /// profile does, which is rarely, and re-asking on every tab switch would
    /// spend the daily allowance on a screen somebody is scrolling past.
    public func loadIfNeeded() async {
        guard guidance == nil, !isLoading else { return }
        await load()
    }

    public func load() async {
        isLoading = true
        defer { isLoading = false }

        // Quietly. The failure is invisible on purpose: everything this view
        // sits above works without it.
        guidance = try? await assistant.recommendations()
    }
}
