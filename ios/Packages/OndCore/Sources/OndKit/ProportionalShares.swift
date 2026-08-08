import Foundation

/// Splitting a whole between parts in proportion to their weights, with a floor
/// under every part.
///
/// Both breathing figures need this and neither can use a plain normalisation.
/// A drawing is a picture of durations that differ by more than an order of
/// magnitude — the physiological sigh's 0.7-second sip beside its five-second
/// exhale, a two-second fast-breath cycle beside a minute-long retention — and a
/// part that renders sub-pixel is a part the reader is told nothing about.
///
/// The floor is applied by repeated passes rather than in one: lifting the
/// smallest parts up rescales the rest into what remains, which can push a
/// mid-sized part below the floor in turn. Each pass floors at least one more
/// part, so the loop is bounded by the part count.
enum ProportionalShares {
    /// Shares summing to one, each at least `floor`, in proportion to `weights`
    /// otherwise.
    ///
    /// The floor is itself capped at an equal split, or the floors alone would
    /// overflow the whole once there are more parts than `1 / floor`.
    static func of(_ weights: [Double], floor requested: Double) -> [Double] {
        guard weights.count > 1 else { return weights.isEmpty ? [] : [1] }

        let total = weights.reduce(0, +)
        guard total > 0 else {
            return Array(repeating: 1 / Double(weights.count), count: weights.count)
        }

        let floor = min(requested, 1 / Double(weights.count))
        var isFloored = [Bool](repeating: false, count: weights.count)
        var shares = weights.map { $0 / total }

        while true {
            let newlyFloored = shares.indices.filter { !isFloored[$0] && shares[$0] < floor }
            if newlyFloored.isEmpty {
                return shares
            }
            for index in newlyFloored {
                isFloored[index] = true
            }

            let remaining = 1 - floor * Double(isFloored.filter(\.self).count)
            let unflooredTotal = weights.indices
                .reduce(0.0) { isFloored[$1] ? $0 : $0 + weights[$1] }
            shares = weights.indices.map { index in
                isFloored[index] ? floor : weights[index] / unflooredTotal * remaining
            }
        }
    }
}
