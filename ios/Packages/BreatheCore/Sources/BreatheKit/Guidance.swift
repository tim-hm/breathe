import Foundation

/// Where a piece of guidance came from.
///
/// The app says "chosen for you" only for `.model`. `.fallback` is not a
/// failure — it is what the server sends when the assistant is unreachable, over
/// quota, or simply not configured, and it is a real answer derived from the
/// goals this person picked. Presenting the two identically would make a claim
/// the app cannot back.
public enum GuidanceSource: Sendable, Equatable {
    case model
    case fallback
}

/// One technique the assistant suggests, and the sentence that justifies it.
///
/// `techniqueSlug` always resolves in the catalogue: the server validates every
/// slug against it before answering, so a view can look this up without a
/// branch for a technique the app has never heard of.
public struct Recommendation: Sendable, Equatable, Identifiable {
    public let techniqueSlug: String
    public let reason: String

    public var id: String {
        techniqueSlug
    }

    public init(techniqueSlug: String, reason: String) {
        self.techniqueSlug = techniqueSlug
        self.reason = reason
    }
}

/// What the assistant suggests, and whether a model wrote it.
public struct Guidance: Sendable, Equatable {
    /// Best first. Never empty when the call succeeded.
    public let recommendations: [Recommendation]
    public let source: GuidanceSource

    public init(recommendations: [Recommendation], source: GuidanceSource) {
        self.recommendations = recommendations
        self.source = source
    }
}

/// A piece of an explanation as it arrives.
///
/// The source rides on every chunk so a view knows how to frame the text from
/// the first one, rather than waiting for the stream to finish to find out.
public struct ExplanationChunk: Sendable, Equatable {
    public let text: String
    public let source: GuidanceSource

    public init(text: String, source: GuidanceSource) {
        self.text = text
        self.source = source
    }
}
