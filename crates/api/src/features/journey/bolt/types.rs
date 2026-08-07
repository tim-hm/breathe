//! What the BOLT history folds down to.

/// The BOLT history folded to the three numbers a coach can use: where they
/// peaked, where they are now, and how much evidence there is for either.
///
/// Unwindowed, unlike the practice half of the snapshot it travels in: a best
/// pause is a personal record, not a recent-form figure.
#[derive(Debug, PartialEq, Eq)]
pub struct BoltSnapshot {
    /// Best pause ever, in seconds.
    pub best: u32,
    /// The most recently measured pause, in seconds.
    pub latest: u32,
    /// How many measurements the caller has ever recorded.
    pub count: u32,
}
