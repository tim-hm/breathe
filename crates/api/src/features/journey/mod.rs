//! Journey — what a person has actually done, and where that puts them.
//!
//! Everything this feature serves is derived on read from two append-only
//! tables. There is no counter to increment and none to repair, which is what
//! lets a client re-send a batch it is unsure about and lets a streak be right
//! in whichever time zone the person is standing in today.

pub mod errors;
pub mod handlers;
pub mod repository;
pub mod service;
pub mod types;
