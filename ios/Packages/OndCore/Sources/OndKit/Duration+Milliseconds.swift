import Foundation

public extension Duration {
    /// Seconds as a `Double`, for the frameworks that measure time that way —
    /// CoreHaptics pattern events, SwiftUI geometry.
    ///
    /// Never for deciding which phase is current: that stays on the integer
    /// milliseconds below, where a boundary cannot land on the wrong side of
    /// itself by a float's breadth.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }

    /// A phase's length as somebody reads it — `4`, or `1.5` for the
    /// physiological sigh's sip of air.
    ///
    /// One decimal at most, and none where the number is whole. Here rather than
    /// at each call site because the same duration is now written in three
    /// places — the Customise dials, the labels on the figure, and the sentence
    /// a screen reader hears — and a precision that differed between them would
    /// read as three different exercises.
    var inSeconds: String {
        seconds.formatted(.number.precision(.fractionLength(0 ... 1)))
    }

    /// The same length as a screen reader should say it — "4 seconds", "1
    /// second", "1.5 seconds".
    ///
    /// `Measurement`'s formatter rather than a hand-rolled plural, because it is
    /// the one that already knows a fractional value takes the plural and that a
    /// localised build will not agree with English about any of this.
    var spokenLength: String {
        Measurement(value: seconds, unit: UnitDuration.seconds)
            .formatted(
                .measurement(
                    width: .wide,
                    numberFormatStyle: .number
                        .precision(.fractionLength(0 ... 1))
                )
            )
    }
}

extension Duration {
    /// Whole milliseconds, truncating.
    ///
    /// Every duration in the catalogue is authored in milliseconds, so integer
    /// arithmetic here is exact where seconds-as-`Double` would land a cycle
    /// boundary a float's breadth on the wrong side of itself.
    var milliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
