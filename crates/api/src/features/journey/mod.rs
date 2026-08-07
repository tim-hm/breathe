//! Journey — what a person has actually done, and where that puts them.
//!
//! Everything this feature serves is derived on read from two append-only
//! tables. There is no counter to increment and none to repair, which is what
//! lets a client re-send a batch it is unsure about and lets a streak be right
//! in whichever time zone the person is standing in today.
//!
//! Tier 3, on the boundary the code already had: `sessions` records and returns
//! history, `bolt` keeps the controlled-pause measurements, and `leaderboard`
//! ranks people against each other. They change for entirely different reasons,
//! and beyond the error type and the wire conversions there is one edge between
//! them — `GetJourney` draws the whole journey screen, including its BOLT card,
//! so `sessions::service` reads the best pause through `bolt`'s *service*. A
//! sub-feature never reaches into a sibling's repository, which is the same rule
//! that holds between features.

pub mod bolt;
pub mod errors;
pub mod handlers;
pub mod leaderboard;
pub mod sessions;
pub mod wire;
