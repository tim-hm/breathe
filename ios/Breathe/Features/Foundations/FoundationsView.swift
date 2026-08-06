import BreatheKit
import BreatheUI
import SwiftUI

/// The questions most breathing apps never answer: belly or chest, nose or
/// mouth, sitting or lying, eyes open or closed.
///
/// Reference data rather than copy, so the same answers can reach the session
/// screen and, later, the assistant. The framing is the point — every one of
/// these is a suggestion, and the footer says so out loud.
struct FoundationsView: View {
    @State private var model: FoundationsModel

    init(model: FoundationsModel) {
        _model = State(wrappedValue: model)
    }

    var body: some View {
        content
            .navigationTitle("The basics")
            .navigationBarTitleDisplayMode(.inline)
            .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()

        case let .loaded(topics):
            List {
                ForEach(topics) { topic in
                    VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                        Text(topic.question)
                            .font(.headline)
                        Text(topic.answer)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.close)
                    .accessibilityElement(children: .combine)
                }

                Text("All of this is a suggestion, never a rule. The breathing works while "
                    + "you're still learning it.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)

        case let .failed(message):
            ContentUnavailableView {
                Label("Can't reach the basics", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") {
                    Task { await model.load() }
                }
            }
        }
    }
}
