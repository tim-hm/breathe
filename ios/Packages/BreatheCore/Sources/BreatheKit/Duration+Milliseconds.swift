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
