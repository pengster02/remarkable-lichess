//! Pure application logic for the reMarkable Lichess client.
//! Deliberately has no dependency on `appload-client` — see this plan's
//! Global Constraints. Later tasks add `pub mod protocol;`, `pub mod lichess;`,
//! `pub mod game;` here, and `#[cfg(feature = "transport")] pub mod backend_app;`
//! once Task 8 introduces it.

pub mod protocol;
