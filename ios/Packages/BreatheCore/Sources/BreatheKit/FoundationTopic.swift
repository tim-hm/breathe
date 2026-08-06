import Foundation

/// One question a beginner has, and the app's answer to it.
///
/// Reference data on the same footing as the catalogue rather than copy baked
/// into a screen: the same rows appear as in-session hints, and M6's assistant
/// cites them instead of inventing its own version of the same advice.
public struct FoundationTopic: Sendable, Identifiable, Hashable {
    /// The stable key. Identity, because a topic's wording is the thing most
    /// likely to change about it.
    public let slug: String
    public let question: String
    public let answer: String

    public var id: String {
        slug
    }

    public init(slug: String, question: String, answer: String) {
        self.slug = slug
        self.question = question
        self.answer = answer
    }
}
