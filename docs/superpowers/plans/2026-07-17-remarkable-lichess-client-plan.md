# reMarkable Lichess Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and deploy an AppLoad app for the reMarkable Paper Pro Move that plays real-time (rapid) Lichess games with legal-move highlighting.

**Architecture:** One AppLoad app = a QML frontend (pure UI, no networking) + a single static Rust backend binary (owns all Lichess networking via the Board API and all chess-rules computation via `shakmaty`), talking only through AppLoad's Unix-socket message protocol. See `docs/superpowers/specs/2026-07-17-remarkable-lichess-client-design.md` for the full design rationale.

**Tech Stack:** Rust (tokio, reqwest, serde, shakmaty, `appload-client`), QML (Qt 6 / QtQuick), Lichess Board API, AppLoad/XOVI (asivery/rm-appload).

## Global Constraints

- Target device: reMarkable Paper Pro Move, 1696×954 16:9 color E Ink, on a Vellum/AppLoad-compatible OS (3.26.x–3.27.x).
- v1 scope only: real-time rapid games, Lichess only, casual/unrated seeks and challenges, no background notifications, no bullet time controls (explicitly out of scope), full challenge/seek UI on-device.
- Backend owns 100% of Lichess networking and chess-rule computation; frontend never talks to Lichess directly and never computes legality itself.
- Legal moves are computed once per position update and cached — tap-to-highlight must be a pure local lookup on the frontend, never a network round-trip.
- Deployment for v1: direct `scp` of the built app bundle into `/home/root/xovi/exthome/appload/<app>/` — no Vellum packaging required to get this running.
- Definition of "v1 done" (from spec): one full real rapid game against a second account, covering seek creation, both sides moving, at least one promotion, and a clean game-over transition back to Home.
- Build-environment constraint (discovered during Task 1): the dev machine is macOS with only the `aarch64-apple-darwin` Rust toolchain installed — no `cross`, no Docker, no Linux cross-target. `appload-client` (the AppLoad transport crate) uses Linux-only raw sockets (`SOCK_SEQPACKET`, `sockaddr_un` layout) that do not compile on macOS. **Every module that touches `appload_client` types (`main.rs` and `backend_app.rs`) is gated behind a Cargo `transport` feature** (`required-features = ["transport"]` on the `[[bin]]`; `#[cfg(feature = "transport")]` on the `backend_app` module declaration in `lib.rs`) — everything else (`protocol`, `lichess::*`, `game::*`) has zero dependency on `appload-client` and is always compiled. Plain `cargo build`/`cargo test` (no flags) therefore builds and tests all the pure logic and automatically skips both gated pieces — standard, documented Cargo behavior, not a workaround. `main.rs` and `backend_app.rs` can only be compiled (with `--features transport`) and tested against real Linux cross-compilation/device tooling, which this sandbox doesn't have — their correctness is verified in Task 14, not earlier.
- Second build-environment constraint (discovered before Task 10): this dev machine also has no Qt/QML toolchain at all — no `qmlformat`, `qmllint`, `qmake`/`qmake6`, no Qt installed via Homebrew. Tasks 10–13's QML cannot be syntax-checked or run on this machine by any means, not even the lightweight lint tools the plan originally called for. Every QML task's implementer verifies by careful inspection against the real AppLoad QML patterns already fetched from `asivery/rm-appload`'s actual example app (in Task 10's context) and against the already-approved backend message shapes (Tasks 2/7/8/9) — actual QML correctness is confirmed only in Task 14, on real device/PC-build tooling the user sets up themselves.

---

## File Structure

```
remarkable-lichess/
  backend/
    Cargo.toml
    src/
      lib.rs                # declares pub mod for every pure-logic module below; no appload-client dependency
      main.rs               # [[bin]], required-features = ["transport"]: entrypoint, AppLoad::new(...).run()
      protocol.rs            # IPC message enums shared between frontend and backend
      lichess/
        mod.rs
        models.rs             # serde structs for Lichess Board API JSON
        stream.rs             # generic NDJSON line-stream parser
        client.rs             # LichessApi trait + reqwest-based implementation
      game/
        mod.rs
        rules.rs              # shakmaty wrapper: legal moves, UCI apply/replay
        session.rs            # GameSession state machine
      backend_app.rs          # AppLoadBackend impl wiring protocol + lichess + game together — `#[cfg(feature = "transport")]`, needs appload_client (see Task 8)
  frontend/
    manifest.json
    application.qrc
    ui/
      main.qml                # AppLoad endpoint + screen switcher
      SetupScreen.qml
      HomeScreen.qml
      SeekScreen.qml
      BoardScreen.qml
      BoardSquare.qml
  scripts/
    build-rm.sh                # cross-compile backend (aarch64) + build QML resources
    deploy.sh                  # scp bundle to /home/root/xovi/exthome/appload/<app>/
```

---

### Task 1: Backend project scaffold — feature-gated echo skeleton

**Files:**
- Create: `backend/Cargo.toml`
- Create: `backend/src/lib.rs`
- Create: `backend/src/main.rs`

**Interfaces:**
- Produces: a `backend` package with a `[lib]` target (empty for now — later tasks add modules to it) that always compiles with no `appload-client` dependency, and a `[[bin]]` target gated behind a `transport` Cargo feature containing the AppLoad echo handler, using the real `appload-client` crate (`asivery/rm-appload`, path `backends/appload-clients/rust-backend`).

This split exists because `appload-client` uses Linux-only raw sockets (`SOCK_SEQPACKET`) that do not compile on macOS — see this plan's Global Constraints. Gating it behind a feature means plain `cargo build`/`cargo test` (what every later task's pure-logic modules use) never touches it.

- [ ] **Step 1: Write `backend/Cargo.toml`**

```toml
[package]
name = "backend"
version = "0.1.0"
edition = "2021"

[lib]
name = "backend"
path = "src/lib.rs"

[[bin]]
name = "backend"
path = "src/main.rs"
required-features = ["transport"]

[dependencies]
appload-client = { git = "https://github.com/asivery/rm-appload", package = "appload-client", optional = true }
async-trait = "0.1.83"
tokio = { version = "1.42.0", features = ["macros", "rt", "rt-multi-thread"] }
anyhow = "1"

[features]
transport = ["dep:appload-client"]
```

Note: `appload-client` is not published on crates.io; if the `git`+`package` form above doesn't resolve because the crate lives at a subpath, clone `asivery/rm-appload` locally and use a `path = "../rm-appload/backends/appload-clients/rust-backend"` dependency instead (keep it `optional = true` either way) — check the repo's actual `Cargo.toml` `[package] name` field to confirm the package name matches `appload-client`. Since this dependency is optional and only resolved/compiled when `--features transport` is passed, do not vendor, fork, or patch the crate's source to work around host-platform (e.g. macOS) compilation issues — that produces an unreproducible build for anyone else who checks out this repo. If it doesn't resolve at all (not even as a git dependency), report BLOCKED rather than working around it by modifying the dependency's own source.

- [ ] **Step 2: Write `backend/src/lib.rs`**

```rust
//! Pure application logic for the reMarkable Lichess client.
//! Deliberately has no dependency on `appload-client` — see this plan's
//! Global Constraints. Later tasks add `pub mod protocol;`, `pub mod lichess;`,
//! `pub mod game;` here, and `#[cfg(feature = "transport")] pub mod backend_app;`
//! once Task 8 introduces it.
```

- [ ] **Step 3: Write `backend/src/main.rs`**

```rust
use appload_client::{AppLoad, AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR};
use async_trait::async_trait;

#[tokio::main]
async fn main() {
    AppLoad::new(EchoBackend).unwrap().run().await.unwrap();
}

struct EchoBackend;

#[async_trait]
impl AppLoadBackend for EchoBackend {
    async fn handle_message(&mut self, functionality: &BackendReplier<EchoBackend>, message: Message) {
        match message.msg_type {
            MSG_SYSTEM_NEW_COORDINATOR => println!("A frontend has connected"),
            1 => {
                functionality
                    .send_message(2, &format!("echo: {}", message.contents))
                    .unwrap();
            }
            _ => println!("Unknown message received."),
        }
    }
}
```

- [ ] **Step 4: Verify the lib builds on this machine with no transport dependency involved**

Run: `cd backend && cargo build`
Expected: compiles with no errors. This builds the (currently empty) `lib` target only — Cargo automatically skips the `backend` bin target because its `required-features = ["transport"]` isn't satisfied by the default feature set. No `appload-client` code is compiled by this command.

- [ ] **Step 5: Record that the transport binary is unverifiable on this machine**

Run: `cd backend && cargo build --features transport`
Expected: this is expected to fail on macOS (no Linux target, `appload-client`'s raw-socket code doesn't compile here) — that failure is not a defect in this task. Do not attempt to fix it by patching `appload-client` or by installing a cross-compilation toolchain as part of this task; cross-compilation setup belongs to Task 14, using real device/cross tooling. Confirm only that the failure is specifically about `appload-client`'s platform-specific code (not a typo or syntax error in `main.rs`), and note the exact error in your report for the record.

- [ ] **Step 6: Commit**

```bash
git add backend/Cargo.toml backend/src/lib.rs backend/src/main.rs
git commit -m "Scaffold feature-gated AppLoad backend with echo handler"
```

---

### Task 2: IPC protocol module

**Files:**
- Create: `backend/src/protocol.rs`
- Modify: `backend/Cargo.toml`

**Interfaces:**
- Produces: `FrontendMessage` (deserialized from frontend), `BackendMessage` (serialized to frontend), `LegalMove`, and the two transport-level type constants `MSG_TYPE_FRONTEND_TO_BACKEND` / `MSG_TYPE_BACKEND_TO_FRONTEND` used by every later task that sends/receives app messages.

- [ ] **Step 1: Add serde to `backend/Cargo.toml`**

```toml
[dependencies]
appload-client = { git = "https://github.com/asivery/rm-appload", package = "appload-client", optional = true }
async-trait = "0.1.83"
tokio = { version = "1.42.0", features = ["macros", "rt", "rt-multi-thread"] }
anyhow = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"

[features]
transport = ["dep:appload-client"]
```

(This re-lists the full `[dependencies]` block per Task 1's actual `backend/Cargo.toml` — keep the `[lib]`/`[[bin]]`/`[features]` sections from Task 1 unchanged; only the `[dependencies]` table gains `serde`/`serde_json` here.)

- [ ] **Step 2: Write the failing test in `backend/src/protocol.rs`**

```rust
use serde::{Deserialize, Serialize};

pub const MSG_TYPE_FRONTEND_TO_BACKEND: u32 = 1;
pub const MSG_TYPE_BACKEND_TO_FRONTEND: u32 = 2;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LegalMove {
    pub from: String,
    pub to: String,
    pub promotion: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum FrontendMessage {
    SaveToken { token: String },
    RequestHome,
    CreateSeek { minutes: u32, increment: u32 },
    CreateChallenge { username: String, minutes: u32, increment: u32 },
    MakeMove { from: String, to: String, promotion: Option<String> },
    Resign,
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(tag = "type")]
pub enum BackendMessage {
    TokenVerified { username: String },
    TokenInvalid { reason: String },
    HomeState { resumable_game_id: Option<String> },
    SeekCreated,
    ChallengeCreated,
    BoardState {
        fen: String,
        turn: String,
        white_time_ms: u64,
        black_time_ms: u64,
        legal_moves: Vec<LegalMove>,
        last_move: Option<(String, String)>,
    },
    GameOver { result: String, reason: String },
    MoveRejected { reason: String },
    Reconnecting,
    ErrorMsg { message: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frontend_message_round_trips_through_json() {
        let json = r#"{"type":"MakeMove","from":"e2","to":"e4","promotion":null}"#;
        let parsed: FrontendMessage = serde_json::from_str(json).unwrap();
        assert_eq!(
            parsed,
            FrontendMessage::MakeMove { from: "e2".into(), to: "e4".into(), promotion: None }
        );
    }

    #[test]
    fn backend_message_serializes_with_type_tag() {
        let msg = BackendMessage::BoardState {
            fen: "startpos".into(),
            turn: "white".into(),
            white_time_ms: 600_000,
            black_time_ms: 600_000,
            legal_moves: vec![LegalMove { from: "e2".into(), to: "e4".into(), promotion: None }],
            last_move: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains(r#""type":"BoardState""#));
        assert!(json.contains(r#""fen":"startpos""#));
    }
}
```

- [ ] **Step 3: Register the module in `backend/src/lib.rs`**

Add to `backend/src/lib.rs` (below the doc comment from Task 1):

```rust
pub mod protocol;
```

- [ ] **Step 4: Run the tests**

Run: `cd backend && cargo test protocol::`
Expected: `2 passed`

- [ ] **Step 5: Commit**

```bash
git add backend/Cargo.toml backend/src/protocol.rs backend/src/lib.rs
git commit -m "Add IPC protocol message types with serde round-trip tests"
```

---

### Task 3: Lichess API models

**Files:**
- Create: `backend/src/lichess/mod.rs`
- Create: `backend/src/lichess/models.rs`

**Interfaces:**
- Produces: `EventStreamMessage`, `GameFull`, `GameState`, `Account`, `PlayingGame` — all deserialized from real Lichess Board API JSON shapes. Consumed by Task 4 (stream parsing), Task 5 (HTTP client), Task 7 (session state machine).

- [ ] **Step 1: Write `backend/src/lichess/models.rs` with failing tests**

```rust
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Account {
    pub id: String,
    pub username: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct PlayingGame {
    #[serde(rename = "gameId")]
    pub game_id: String,
    #[serde(rename = "isMyTurn")]
    pub is_my_turn: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct PlayingResponse {
    #[serde(rename = "nowPlaying")]
    pub now_playing: Vec<PlayingGame>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct Clock {
    pub initial: u64,
    pub increment: u64,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameState {
    pub moves: String,
    pub wtime: u64,
    pub btime: u64,
    pub winc: u64,
    pub binc: u64,
    pub status: String,
    pub winner: Option<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct GameFull {
    pub id: String,
    pub rated: bool,
    #[serde(rename = "initialFen")]
    pub initial_fen: String,
    pub clock: Option<Clock>,
    pub state: GameState,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum GameStreamMessage {
    #[serde(rename = "gameFull")]
    Full(GameFull),
    #[serde(rename = "gameState")]
    State(GameState),
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
pub struct EventGame {
    pub id: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(tag = "type")]
pub enum EventStreamMessage {
    #[serde(rename = "gameStart")]
    GameStart { game: EventGame },
    #[serde(rename = "gameFinish")]
    GameFinish { game: EventGame },
    #[serde(other)]
    Other,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_game_full_then_game_state() {
        let full_json = r#"{"type":"gameFull","id":"abcd1234","rated":false,"initialFen":"startpos","clock":{"initial":600000,"increment":0},"state":{"type":"gameState","moves":"","wtime":600000,"btime":600000,"winc":0,"binc":0,"status":"started","winner":null}}"#;
        let msg: GameStreamMessage = serde_json::from_str(full_json).unwrap();
        match msg {
            GameStreamMessage::Full(full) => {
                assert_eq!(full.id, "abcd1234");
                assert_eq!(full.state.status, "started");
            }
            _ => panic!("expected Full variant"),
        }

        let state_json = r#"{"type":"gameState","moves":"e2e4","wtime":598000,"btime":600000,"winc":0,"binc":0,"status":"started","winner":null}"#;
        let msg: GameStreamMessage = serde_json::from_str(state_json).unwrap();
        match msg {
            GameStreamMessage::State(state) => assert_eq!(state.moves, "e2e4"),
            _ => panic!("expected State variant"),
        }
    }

    #[test]
    fn parses_game_start_event() {
        let json = r#"{"type":"gameStart","game":{"id":"abcd1234"}}"#;
        let msg: EventStreamMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg, EventStreamMessage::GameStart { game: EventGame { id: "abcd1234".into() } });
    }

    #[test]
    fn parses_playing_response() {
        let json = r#"{"nowPlaying":[{"gameId":"abcd1234","isMyTurn":true}]}"#;
        let parsed: PlayingResponse = serde_json::from_str(json).unwrap();
        assert_eq!(parsed.now_playing.len(), 1);
        assert_eq!(parsed.now_playing[0].game_id, "abcd1234");
        assert!(parsed.now_playing[0].is_my_turn);
    }
}
```

Note: these structs cover only the fields this app uses (Lichess responses include many more). Cross-check field names against `https://lichess.org/api` if any deserialization fails on real traffic in Task 14 — the Board API has been stable for years but verify before assuming a mismatch is a bug in this code.

- [ ] **Step 2: Write `backend/src/lichess/mod.rs`**

```rust
pub mod models;
```

- [ ] **Step 3: Register in `backend/src/lib.rs`**

Add: `pub mod lichess;` below `pub mod protocol;`

- [ ] **Step 4: Run the tests**

Run: `cd backend && cargo test lichess::models::`
Expected: `3 passed`

- [ ] **Step 5: Commit**

```bash
git add backend/src/lichess/mod.rs backend/src/lichess/models.rs backend/src/lib.rs
git commit -m "Add Lichess Board API model structs with deserialization tests"
```

---

### Task 4: NDJSON stream parser

**Files:**
- Create: `backend/src/lichess/stream.rs`
- Modify: `backend/Cargo.toml`
- Modify: `backend/src/lichess/mod.rs`

**Interfaces:**
- Consumes: any type implementing `serde::de::DeserializeOwned` (used with `EventStreamMessage` / `GameStreamMessage` from Task 3).
- Produces: `parse_ndjson_line<T>(line: &str) -> Option<T>` — used by Task 5's streaming methods and Task 8's orchestration loop.

- [ ] **Step 1: Add `tokio` stream features to `backend/Cargo.toml`**

```toml
[dependencies]
appload-client = { git = "https://github.com/asivery/rm-appload", package = "appload-client", optional = true }
async-trait = "0.1.83"
tokio = { version = "1.42.0", features = ["macros", "rt", "rt-multi-thread", "io-util"] }
anyhow = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"

[features]
transport = ["dep:appload-client"]
```

- [ ] **Step 2: Write the failing test in `backend/src/lichess/stream.rs`**

```rust
use serde::de::DeserializeOwned;

/// Lichess NDJSON streams send a blank line periodically as a keep-alive.
/// Returns `None` for blank lines and lines that fail to parse as `T`.
pub fn parse_ndjson_line<T: DeserializeOwned>(line: &str) -> Option<T> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    serde_json::from_str(trimmed).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lichess::models::{EventStreamMessage, EventGame};

    #[test]
    fn skips_blank_keepalive_lines() {
        assert!(parse_ndjson_line::<EventStreamMessage>("").is_none());
        assert!(parse_ndjson_line::<EventStreamMessage>("   \n").is_none());
    }

    #[test]
    fn parses_a_valid_line() {
        let line = r#"{"type":"gameStart","game":{"id":"abcd1234"}}"#;
        let parsed: EventStreamMessage = parse_ndjson_line(line).unwrap();
        assert_eq!(parsed, EventStreamMessage::GameStart { game: EventGame { id: "abcd1234".into() } });
    }

    #[test]
    fn returns_none_for_malformed_json() {
        assert!(parse_ndjson_line::<EventStreamMessage>("{not json").is_none());
    }
}
```

- [ ] **Step 3: Add to `backend/src/lichess/mod.rs`**

```rust
pub mod models;
pub mod stream;
```

- [ ] **Step 4: Run the tests**

Run: `cd backend && cargo test lichess::stream::`
Expected: `3 passed`

- [ ] **Step 5: Commit**

```bash
git add backend/Cargo.toml backend/src/lichess/mod.rs backend/src/lichess/stream.rs
git commit -m "Add NDJSON line parser for Lichess streaming endpoints"
```

---

### Task 5: Lichess HTTP client

**Files:**
- Create: `backend/src/lichess/client.rs`
- Modify: `backend/Cargo.toml`
- Modify: `backend/src/lichess/mod.rs`

**Interfaces:**
- Consumes: `models::{Account, PlayingResponse}` (Task 3).
- Produces: `LichessClient::new(token: String) -> LichessClient`, `async fn get_account(&self) -> anyhow::Result<Account>`, `async fn get_playing(&self) -> anyhow::Result<Vec<PlayingGame>>`, `async fn create_seek(&self, minutes: u32, increment: u32) -> anyhow::Result<()>`, `async fn create_challenge(&self, username: &str, minutes: u32, increment: u32) -> anyhow::Result<()>`, `async fn make_move(&self, game_id: &str, uci: &str) -> anyhow::Result<()>`, `async fn resign(&self, game_id: &str) -> anyhow::Result<()>`. Consumed by Task 8.

- [ ] **Step 1: Add `reqwest` and `wiremock` to `backend/Cargo.toml`**

```toml
[dependencies]
appload-client = { git = "https://github.com/asivery/rm-appload", package = "appload-client", optional = true }
async-trait = "0.1.83"
tokio = { version = "1.42.0", features = ["macros", "rt", "rt-multi-thread", "io-util"] }
anyhow = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = { version = "0.12", features = ["json"] }

[dev-dependencies]
wiremock = "0.6"

[features]
transport = ["dep:appload-client"]
```

- [ ] **Step 2: Write the failing test in `backend/src/lichess/client.rs`**

```rust
use crate::lichess::models::{Account, PlayingGame, PlayingResponse};
use anyhow::{bail, Result};

pub struct LichessClient {
    http: reqwest::Client,
    base_url: String,
    token: String,
}

impl LichessClient {
    pub fn new(token: String) -> Self {
        Self::with_base_url(token, "https://lichess.org".to_string())
    }

    pub fn with_base_url(token: String, base_url: String) -> Self {
        Self { http: reqwest::Client::new(), base_url, token }
    }

    fn bearer(&self, builder: reqwest::RequestBuilder) -> reqwest::RequestBuilder {
        builder.bearer_auth(&self.token)
    }

    pub async fn get_account(&self) -> Result<Account> {
        let resp = self
            .bearer(self.http.get(format!("{}/api/account", self.base_url)))
            .send()
            .await?;
        if !resp.status().is_success() {
            bail!("get_account failed with status {}", resp.status());
        }
        Ok(resp.json::<Account>().await?)
    }

    pub async fn get_playing(&self) -> Result<Vec<PlayingGame>> {
        let resp = self
            .bearer(self.http.get(format!("{}/api/account/playing", self.base_url)))
            .send()
            .await?;
        if !resp.status().is_success() {
            bail!("get_playing failed with status {}", resp.status());
        }
        let parsed = resp.json::<PlayingResponse>().await?;
        Ok(parsed.now_playing)
    }

    pub async fn make_move(&self, game_id: &str, uci: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!(
                "{}/api/board/game/{}/move/{}",
                self.base_url, game_id, uci
            )))
            .send()
            .await?;
        if !resp.status().is_success() {
            bail!("make_move failed with status {}", resp.status());
        }
        Ok(())
    }

    pub async fn resign(&self, game_id: &str) -> Result<()> {
        let resp = self
            .bearer(self.http.post(format!(
                "{}/api/board/game/{}/resign",
                self.base_url, game_id
            )))
            .send()
            .await?;
        if !resp.status().is_success() {
            bail!("resign failed with status {}", resp.status());
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn get_account_sends_bearer_token_and_parses_response() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/account"))
            .and(header("Authorization", "Bearer test-token"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "id": "abc123",
                "username": "testuser"
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let account = client.get_account().await.unwrap();
        assert_eq!(account.username, "testuser");
    }

    #[tokio::test]
    async fn get_playing_parses_now_playing_list() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/account/playing"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "nowPlaying": [{"gameId": "g1", "isMyTurn": true}]
            })))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        let games = client.get_playing().await.unwrap();
        assert_eq!(games.len(), 1);
        assert_eq!(games[0].game_id, "g1");
    }

    #[tokio::test]
    async fn make_move_posts_uci_to_correct_path() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/api/board/game/g1/move/e2e4"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"ok": true})))
            .mount(&server)
            .await;

        let client = LichessClient::with_base_url("test-token".into(), server.uri());
        client.make_move("g1", "e2e4").await.unwrap();
    }
}
```

- [ ] **Step 3: Add to `backend/src/lichess/mod.rs`**

```rust
pub mod client;
pub mod models;
pub mod stream;
```

- [ ] **Step 4: Run the tests**

Run: `cd backend && cargo test lichess::client::`
Expected: `3 passed`

- [ ] **Step 5: Commit**

```bash
git add backend/Cargo.toml backend/src/lichess/mod.rs backend/src/lichess/client.rs
git commit -m "Add Lichess HTTP client with wiremock-tested account/move endpoints"
```

---

### Task 6: Chess rules wrapper

**Files:**
- Create: `backend/src/game/mod.rs`
- Create: `backend/src/game/rules.rs`
- Modify: `backend/Cargo.toml`

**Interfaces:**
- Produces: `legal_moves(pos: &shakmaty::Chess) -> Vec<LegalMove>` (using `protocol::LegalMove` from Task 2), `replay_uci_moves(initial_fen: &str, moves: &str) -> anyhow::Result<shakmaty::Chess>`, `apply_uci_move(pos: &shakmaty::Chess, uci: &str) -> anyhow::Result<shakmaty::Chess>`. Consumed by Task 7.

- [ ] **Step 1: Add `shakmaty` to `backend/Cargo.toml`**

```toml
[dependencies]
appload-client = { git = "https://github.com/asivery/rm-appload", package = "appload-client", optional = true }
async-trait = "0.1.83"
tokio = { version = "1.42.0", features = ["macros", "rt", "rt-multi-thread", "io-util"] }
anyhow = "1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
reqwest = { version = "0.12", features = ["json"] }
shakmaty = "0.27"

[dev-dependencies]
wiremock = "0.6"

[features]
transport = ["dep:appload-client"]
```

Note: the exact `shakmaty` method names below (`UciMove::from_move`, `pos.castles().mode()`, `fen.into_position(...)`) reflect the crate's well-established public API as of the versions around `0.27`, but were written from documentation knowledge rather than a real `cargo build` run against the live crate (unlike the earlier `appload-client`/Lichess snippets in this plan, which were fetched verbatim from real source). If `cargo build` in Step 4 reports a missing method or type mismatch, check `https://docs.rs/shakmaty` for the exact signatures in whatever version `cargo` resolves and adjust — the intent (compute legal moves, convert to/from UCI, parse/emit FEN) stays the same regardless of the exact call shape.

- [ ] **Step 2: Write the failing test in `backend/src/game/rules.rs`**

```rust
use crate::protocol::LegalMove;
use anyhow::{Context, Result};
use shakmaty::{fen::Fen, uci::UciMove, CastlingMode, Chess, Position};

pub fn legal_moves(pos: &Chess) -> Vec<LegalMove> {
    pos.legal_moves()
        .iter()
        .map(|m| {
            let uci = UciMove::from_move(m, pos.castles().mode());
            let s = uci.to_string();
            // UCI squares are always the first four characters, e.g. "e2e4" or "e7e8q"
            let from = s[0..2].to_string();
            let to = s[2..4].to_string();
            let promotion = if s.len() > 4 { Some(s[4..5].to_string()) } else { None };
            LegalMove { from, to, promotion }
        })
        .collect()
}

pub fn starting_position(initial_fen: &str) -> Result<Chess> {
    if initial_fen == "startpos" {
        return Ok(Chess::default());
    }
    let fen: Fen = initial_fen.parse().context("parsing initial FEN")?;
    fen.into_position(CastlingMode::Standard).context("building position from FEN")
}

pub fn replay_uci_moves(initial_fen: &str, moves: &str) -> Result<Chess> {
    let mut pos = starting_position(initial_fen)?;
    if moves.trim().is_empty() {
        return Ok(pos);
    }
    for uci_str in moves.split_whitespace() {
        pos = apply_uci_move(&pos, uci_str)?;
    }
    Ok(pos)
}

pub fn apply_uci_move(pos: &Chess, uci_str: &str) -> Result<Chess> {
    let uci: UciMove = uci_str.parse().context("parsing UCI move")?;
    let m = uci.to_move(pos).context("resolving UCI move against position")?;
    let mut new_pos = pos.clone();
    new_pos.play_unchecked(&m);
    Ok(new_pos)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starting_position_has_twenty_legal_moves() {
        let pos = starting_position("startpos").unwrap();
        assert_eq!(legal_moves(&pos).len(), 20);
    }

    #[test]
    fn replaying_two_moves_produces_expected_position() {
        let pos = replay_uci_moves("startpos", "e2e4 e7e5").unwrap();
        // After 1. e4 e5, it's White to move again with 29 legal replies (known good position).
        assert_eq!(legal_moves(&pos).len(), 29);
    }

    #[test]
    fn illegal_uci_move_is_rejected() {
        let pos = starting_position("startpos").unwrap();
        assert!(apply_uci_move(&pos, "e2e5").is_err());
    }
}
```

- [ ] **Step 3: Write `backend/src/game/mod.rs`**

```rust
pub mod rules;
```

- [ ] **Step 4: Register in `backend/src/lib.rs`**

Add: `pub mod game;` below `pub mod lichess;`

- [ ] **Step 5: Run the tests**

Run: `cd backend && cargo test game::rules::`
Expected: `3 passed`

- [ ] **Step 6: Commit**

```bash
git add backend/Cargo.toml backend/src/game/mod.rs backend/src/game/rules.rs backend/src/lib.rs
git commit -m "Add shakmaty-based chess rules wrapper with legal-move tests"
```

---

### Task 7: Game session state machine

**Files:**
- Create: `backend/src/game/session.rs`
- Modify: `backend/src/game/mod.rs`

**Interfaces:**
- Consumes: `rules::{replay_uci_moves, apply_uci_move, legal_moves}` (Task 6), `protocol::{BackendMessage, LegalMove}` (Task 2), `lichess::models::{GameFull, GameState}` (Task 3).
- Produces: `GameSession::from_game_full(full: &GameFull) -> GameSession`, `fn apply_state_update(&mut self, state: &GameState) -> BackendMessage`, `fn try_move(&self, from: &str, to: &str, promotion: Option<&str>) -> Result<String, BackendMessage>` (returns the UCI string to submit, or a `MoveRejected` message if the move isn't in the cached legal list). Consumed by Task 8.

- [ ] **Step 1: Write the failing test in `backend/src/game/session.rs`**

```rust
use crate::game::rules::{apply_uci_move, legal_moves, replay_uci_moves};
use crate::lichess::models::{GameFull, GameState};
use crate::protocol::{BackendMessage, LegalMove};
use shakmaty::Chess;

pub struct GameSession {
    pub game_id: String,
    pub initial_fen: String,
    pub position: Chess,
    pub legal: Vec<LegalMove>,
    pub last_move: Option<(String, String)>,
}

fn turn_name(pos: &Chess) -> String {
    use shakmaty::{Color, Position};
    match pos.turn() {
        Color::White => "white".to_string(),
        Color::Black => "black".to_string(),
    }
}

fn to_board_state(session: &GameSession, state: &GameState) -> BackendMessage {
    BackendMessage::BoardState {
        fen: shakmaty::fen::Fen::from_position(session.position.clone(), shakmaty::EnPassantMode::Legal).to_string(),
        turn: turn_name(&session.position),
        white_time_ms: state.wtime,
        black_time_ms: state.btime,
        legal_moves: session.legal.clone(),
        last_move: session.last_move.clone(),
    }
}

fn last_move_from_uci_list(moves: &str) -> Option<(String, String)> {
    let last = moves.split_whitespace().last()?;
    if last.len() < 4 {
        return None;
    }
    Some((last[0..2].to_string(), last[2..4].to_string()))
}

impl GameSession {
    pub fn from_game_full(full: &GameFull) -> anyhow::Result<(Self, BackendMessage)> {
        let position = replay_uci_moves(&full.initial_fen, &full.state.moves)?;
        let legal = legal_moves(&position);
        let last_move = last_move_from_uci_list(&full.state.moves);
        let session = GameSession {
            game_id: full.id.clone(),
            initial_fen: full.initial_fen.clone(),
            position,
            legal,
            last_move,
        };
        let msg = to_board_state(&session, &full.state);
        Ok((session, msg))
    }

    pub fn apply_state_update(&mut self, state: &GameState) -> anyhow::Result<BackendMessage> {
        self.position = replay_uci_moves(&self.initial_fen, &state.moves)?;
        self.legal = legal_moves(&self.position);
        self.last_move = last_move_from_uci_list(&state.moves);
        Ok(to_board_state(self, state))
    }

    /// Returns the UCI string to submit to Lichess, or a MoveRejected message
    /// if `from`/`to`/`promotion` isn't in the cached legal-move list.
    pub fn try_move(&self, from: &str, to: &str, promotion: Option<&str>) -> Result<String, BackendMessage> {
        let found = self.legal.iter().find(|m| {
            m.from == from && m.to == to && m.promotion.as_deref() == promotion
        });
        match found {
            Some(_) => {
                let mut uci = format!("{}{}", from, to);
                if let Some(p) = promotion {
                    uci.push_str(p);
                }
                // Defense in depth: confirm shakmaty still accepts it against our cached position
                // before trusting it, in case of a stale-cache race with an opponent move.
                match apply_uci_move(&self.position, &uci) {
                    Ok(_) => Ok(uci),
                    Err(_) => Err(BackendMessage::MoveRejected { reason: "stale board state, please retry".into() }),
                }
            }
            None => Err(BackendMessage::MoveRejected { reason: "not a legal move".into() }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lichess::models::GameFull;

    fn sample_full(moves: &str) -> GameFull {
        serde_json::from_value(serde_json::json!({
            "type": "gameFull",
            "id": "g1",
            "rated": false,
            "initialFen": "startpos",
            "clock": {"initial": 600000, "increment": 0},
            "state": {
                "type": "gameState",
                "moves": moves,
                "wtime": 600000,
                "btime": 600000,
                "winc": 0,
                "binc": 0,
                "status": "started",
                "winner": null
            }
        }))
        .unwrap()
    }

    #[test]
    fn from_game_full_produces_board_state_with_twenty_legal_moves() {
        let full = sample_full("");
        let (_session, msg) = GameSession::from_game_full(&full).unwrap();
        match msg {
            BackendMessage::BoardState { legal_moves, turn, .. } => {
                assert_eq!(legal_moves.len(), 20);
                assert_eq!(turn, "white");
            }
            _ => panic!("expected BoardState"),
        }
    }

    #[test]
    fn try_move_accepts_a_cached_legal_move() {
        let full = sample_full("");
        let (session, _msg) = GameSession::from_game_full(&full).unwrap();
        let uci = session.try_move("e2", "e4", None).unwrap();
        assert_eq!(uci, "e2e4");
    }

    #[test]
    fn try_move_rejects_a_move_not_in_the_legal_cache() {
        let full = sample_full("");
        let (session, _msg) = GameSession::from_game_full(&full).unwrap();
        let result = session.try_move("e2", "e5", None);
        assert!(matches!(result, Err(BackendMessage::MoveRejected { .. })));
    }

    #[test]
    fn apply_state_update_advances_position_and_last_move() {
        let full = sample_full("");
        let (mut session, _msg) = GameSession::from_game_full(&full).unwrap();
        let state: GameState = serde_json::from_value(serde_json::json!({
            "moves": "e2e4",
            "wtime": 598000,
            "btime": 600000,
            "winc": 0,
            "binc": 0,
            "status": "started",
            "winner": null
        }))
        .unwrap();
        let msg = session.apply_state_update(&state).unwrap();
        match msg {
            BackendMessage::BoardState { last_move, turn, .. } => {
                assert_eq!(last_move, Some(("e2".to_string(), "e4".to_string())));
                assert_eq!(turn, "black");
            }
            _ => panic!("expected BoardState"),
        }
    }
}
```

- [ ] **Step 2: Add to `backend/src/game/mod.rs`**

```rust
pub mod rules;
pub mod session;
```

- [ ] **Step 3: Run the tests**

Run: `cd backend && cargo test game::session::`
Expected: `4 passed`

- [ ] **Step 4: Commit**

```bash
git add backend/src/game/mod.rs backend/src/game/session.rs
git commit -m "Add GameSession state machine translating Lichess updates to BoardState"
```

---

### Task 8: Backend orchestration

**Files:**
- Create: `backend/src/backend_app.rs`
- Modify: `backend/src/lib.rs`
- Modify: `backend/src/main.rs`

**Interfaces:**
- Consumes: everything from Tasks 2–7 (`protocol`, `lichess::client::LichessClient`, `lichess::stream::parse_ndjson_line`, `lichess::models::*`, `game::session::GameSession`).
- Produces: `LichessBackend`, the real `AppLoadBackend` implementation replacing Task 1's echo handler — this is what actually runs on-device.

Note: `backend_app.rs` imports `appload_client` types directly, so — per this plan's Global Constraints — it is only ever compiled behind the `transport` feature. It cannot be built or tested on this dev machine (no Linux target); its correctness is verified in Task 14. What *is* verifiable here is everything this task adds to `client.rs` (`create_seek`/`create_challenge`), since `lichess::client` remains an always-on module.

- [ ] **Step 1: Write `backend/src/backend_app.rs`**

```rust
use crate::game::session::GameSession;
use crate::lichess::client::LichessClient;
use crate::protocol::{BackendMessage, FrontendMessage, MSG_TYPE_BACKEND_TO_FRONTEND};
use appload_client::{AppLoadBackend, BackendReplier, Message, MSG_SYSTEM_NEW_COORDINATOR};
use async_trait::async_trait;
use std::path::PathBuf;

pub struct LichessBackend {
    token_path: PathBuf,
    client: Option<LichessClient>,
    session: Option<GameSession>,
}

impl LichessBackend {
    pub fn new(token_path: PathBuf) -> Self {
        Self { token_path, client: None, session: None }
    }

    fn send(&self, replier: &BackendReplier<Self>, msg: &BackendMessage) {
        let json = serde_json::to_string(msg).expect("BackendMessage always serializes");
        let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
    }

    async fn handle_save_token(&mut self, replier: &BackendReplier<Self>, token: String) {
        let client = LichessClient::new(token.clone());
        match client.get_account().await {
            Ok(account) => {
                let _ = std::fs::write(&self.token_path, &token);
                self.client = Some(client);
                self.send(replier, &BackendMessage::TokenVerified { username: account.username });
            }
            Err(e) => {
                self.send(replier, &BackendMessage::TokenInvalid { reason: e.to_string() });
            }
        }
    }

    async fn handle_request_home(&mut self, replier: &BackendReplier<Self>) {
        let Some(client) = &self.client else {
            self.send(replier, &BackendMessage::TokenInvalid { reason: "no token saved".into() });
            return;
        };
        match client.get_playing().await {
            Ok(games) => {
                let resumable = games.first().map(|g| g.game_id.clone());
                self.send(replier, &BackendMessage::HomeState { resumable_game_id: resumable });
            }
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
        }
    }

    async fn handle_create_seek(&mut self, replier: &BackendReplier<Self>, minutes: u32, increment: u32) {
        let Some(client) = &self.client else { return };
        match client.create_seek(minutes, increment).await {
            Ok(()) => self.send(replier, &BackendMessage::SeekCreated),
            Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
        }
    }

    async fn handle_make_move(&mut self, replier: &BackendReplier<Self>, from: String, to: String, promotion: Option<String>) {
        let (Some(client), Some(session)) = (&self.client, &self.session) else { return };
        match session.try_move(&from, &to, promotion.as_deref()) {
            Ok(uci) => {
                if let Err(e) = client.make_move(&session.game_id, &uci).await {
                    self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() });
                }
                // The authoritative BoardState update arrives via the game stream
                // (wired in a follow-up task covering the streaming loop), not here.
            }
            Err(rejected) => self.send(replier, &rejected),
        }
    }
}

#[async_trait]
impl AppLoadBackend for LichessBackend {
    async fn handle_message(&mut self, replier: &BackendReplier<Self>, message: Message) {
        if message.msg_type == MSG_SYSTEM_NEW_COORDINATOR {
            return;
        }
        let Ok(frontend_msg) = serde_json::from_str::<FrontendMessage>(&message.contents) else {
            self.send(replier, &BackendMessage::ErrorMsg { message: "malformed message from frontend".into() });
            return;
        };
        match frontend_msg {
            FrontendMessage::SaveToken { token } => self.handle_save_token(replier, token).await,
            FrontendMessage::RequestHome => self.handle_request_home(replier).await,
            FrontendMessage::CreateSeek { minutes, increment } => {
                self.handle_create_seek(replier, minutes, increment).await
            }
            FrontendMessage::CreateChallenge { username, minutes, increment } => {
                let Some(client) = &self.client else { return };
                match client.create_challenge(&username, minutes, increment).await {
                    Ok(()) => self.send(replier, &BackendMessage::ChallengeCreated),
                    Err(e) => self.send(replier, &BackendMessage::ErrorMsg { message: e.to_string() }),
                }
            }
            FrontendMessage::MakeMove { from, to, promotion } => {
                self.handle_make_move(replier, from, to, promotion).await
            }
            FrontendMessage::Resign => {
                if let (Some(client), Some(session)) = (&self.client, &self.session) {
                    let _ = client.resign(&session.game_id).await;
                }
            }
        }
    }
}
```

Note: `LichessClient::create_seek` / `create_challenge` are declared in Task 5's interface list but not implemented in Task 5's code sample (only `get_account`, `get_playing`, `make_move`, `resign` were). Add them to `backend/src/lichess/client.rs` as part of this task's Step 1, following the exact same `bearer(...).send().await` pattern as `make_move`, posting form-encoded bodies:

```rust
pub async fn create_seek(&self, minutes: u32, increment: u32) -> Result<()> {
    let resp = self
        .bearer(self.http.post(format!("{}/api/board/seek", self.base_url)))
        .form(&[
            ("rated", "false".to_string()),
            ("time", minutes.to_string()),
            ("increment", increment.to_string()),
        ])
        .send()
        .await?;
    if !resp.status().is_success() {
        bail!("create_seek failed with status {}", resp.status());
    }
    Ok(())
}

pub async fn create_challenge(&self, username: &str, minutes: u32, increment: u32) -> Result<()> {
    let resp = self
        .bearer(self.http.post(format!("{}/api/challenge/{}", self.base_url, username)))
        .form(&[
            ("rated", "false".to_string()),
            ("clock.limit", (minutes * 60).to_string()),
            ("clock.increment", increment.to_string()),
        ])
        .send()
        .await?;
    if !resp.status().is_success() {
        bail!("create_challenge failed with status {}", resp.status());
    }
    Ok(())
}
```

Note: `/api/board/seek` and `/api/challenge/{username}` are themselves long-lived streaming requests in the real Lichess API (the connection stays open until matched). This simplified version treats them as fire-and-forget POSTs — acceptable for v1 because the frontend learns about the actual game start from the account event stream (wired in a follow-up task), not from this call's response. Revisit if testing in Task 14 shows the connection needs to be kept open explicitly.

- [ ] **Step 2: Register `backend_app` behind the transport feature in `backend/src/lib.rs`**

Add below the `pub mod game;` line from Task 6:

```rust
#[cfg(feature = "transport")]
pub mod backend_app;
```

- [ ] **Step 3: Replace the echo handler in `backend/src/main.rs`**

```rust
use appload_client::AppLoad;
use backend::backend_app::LichessBackend;
use std::path::PathBuf;

#[tokio::main]
async fn main() {
    let token_path = PathBuf::from("/home/root/.config/remarkable-lichess/token");
    if let Some(parent) = token_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    AppLoad::new(LichessBackend::new(token_path)).unwrap().run().await.unwrap();
}
```

- [ ] **Step 4: Add `create_seek`/`create_challenge` tests to `backend/src/lichess/client.rs`**

```rust
#[tokio::test]
async fn create_seek_posts_form_encoded_time_control() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/api/board/seek"))
        .respond_with(ResponseTemplate::new(200))
        .mount(&server)
        .await;

    let client = LichessClient::with_base_url("test-token".into(), server.uri());
    client.create_seek(10, 0).await.unwrap();
}
```

- [ ] **Step 5: Run the always-on test suite**

Run: `cd backend && cargo build && cargo test`
Expected: both commands build/test the `lib` target only (the bin is skipped per its `required-features`, and `backend_app` is skipped per its own `#[cfg(feature = "transport")]`) — all tests from Tasks 2–7 plus this task's two new `client::` tests pass (protocol: 2, lichess::models: 3, lichess::stream: 3, lichess::client: 6, game::rules: 3, game::session: 4). This does **not** verify `backend_app.rs` or the rewritten `main.rs` compile — record in your report that those two files are unverified on this machine, same as Task 1's bin target, pending Task 14.

- [ ] **Step 6: Commit**

```bash
git add backend/src/backend_app.rs backend/src/lib.rs backend/src/main.rs backend/src/lichess/client.rs
git commit -m "Wire real LichessBackend handler replacing the echo skeleton"
```

---

### Task 9: Streaming loop (account events + per-game state)

**Files:**
- Modify: `backend/src/backend_app.rs`
- Modify: `backend/Cargo.toml`

**Interfaces:**
- Consumes: `lichess::stream::parse_ndjson_line`, `lichess::models::{EventStreamMessage, GameStreamMessage}`, `game::session::GameSession`.
- Produces: background `tokio` tasks that push unsolicited `BackendMessage::BoardState` / `GameOver` / `Reconnecting` updates to the frontend as they arrive from Lichess, independent of any frontend request. This is what makes opponent moves show up without the frontend polling.

- [ ] **Step 1: Add streaming methods to `backend/src/lichess/client.rs`**

```rust
use futures_util::StreamExt;

impl LichessClient {
    pub async fn stream_lines(&self, url_path: &str) -> Result<impl futures_util::Stream<Item = String>> {
        let resp = self
            .bearer(self.http.get(format!("{}{}", self.base_url, url_path)))
            .send()
            .await?;
        if !resp.status().is_success() {
            bail!("stream {} failed with status {}", url_path, resp.status());
        }
        let byte_stream = resp.bytes_stream();
        Ok(byte_stream
            .filter_map(|chunk| async move { chunk.ok() })
            .flat_map(|bytes| {
                let text = String::from_utf8_lossy(&bytes).to_string();
                futures_util::stream::iter(
                    text.lines().map(str::to_string).collect::<Vec<_>>(),
                )
            }))
    }
}
```

Add to `backend/Cargo.toml`:

```toml
futures-util = "0.3"
```

Note: this line-splitting is simplified — it assumes each network chunk boundary aligns with a line boundary, which holds for Lichess's NDJSON streams in practice but is not guaranteed by the HTTP spec in general. If Task 14's on-device testing shows occasional parse failures on real traffic, replace this with a proper buffering line-reader (e.g. accumulate a `String` buffer across chunks and only emit up to the last `\n`).

- [ ] **Step 2: Add the streaming loop to `LichessBackend` in `backend/src/backend_app.rs`**

```rust
use crate::lichess::models::{EventStreamMessage, GameStreamMessage};
use crate::lichess::stream::parse_ndjson_line;
use tokio::sync::mpsc;

impl LichessBackend {
    pub fn spawn_streams(&self, replier: BackendReplier<Self>) {
        let Some(client) = self.client.clone() else { return };
        tokio::spawn(async move {
            loop {
                match client.stream_lines("/api/stream/event").await {
                    Ok(mut lines) => {
                        use futures_util::StreamExt;
                        while let Some(line) = lines.next().await {
                            if let Some(EventStreamMessage::GameStart { game }) =
                                parse_ndjson_line::<EventStreamMessage>(&line)
                            {
                                spawn_game_stream(client.clone(), game.id, replier.clone());
                            }
                        }
                    }
                    Err(_) => {
                        let json = serde_json::to_string(&BackendMessage::Reconnecting).unwrap();
                        let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
                    }
                }
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
            }
        });
    }
}

fn spawn_game_stream(client: LichessClient, game_id: String, replier: BackendReplier<LichessBackend>) {
    tokio::spawn(async move {
        use futures_util::StreamExt;
        if let Ok(mut lines) = client.stream_lines(&format!("/api/board/game/stream/{}", game_id)).await {
            let mut session: Option<GameSession> = None;
            while let Some(line) = lines.next().await {
                if let Some(msg) = parse_ndjson_line::<GameStreamMessage>(&line) {
                    let board_msg = match (&mut session, msg) {
                        (None, GameStreamMessage::Full(full)) => {
                            match GameSession::from_game_full(&full) {
                                Ok((s, board_msg)) => {
                                    session = Some(s);
                                    Some(board_msg)
                                }
                                Err(_) => None,
                            }
                        }
                        (Some(s), GameStreamMessage::State(state)) => {
                            let is_over = state.status != "started";
                            let result = s.apply_state_update(&state).ok();
                            if is_over {
                                Some(BackendMessage::GameOver {
                                    result: state.winner.clone().unwrap_or_else(|| "draw".into()),
                                    reason: state.status.clone(),
                                })
                            } else {
                                result
                            }
                        }
                        _ => None,
                    };
                    if let Some(m) = board_msg {
                        let json = serde_json::to_string(&m).unwrap();
                        let _ = replier.send_message(MSG_TYPE_BACKEND_TO_FRONTEND, &json);
                    }
                }
            }
        }
    });
}
```

Note: `LichessClient` needs `#[derive(Clone)]` for this to compile (spawned tasks each need their own handle) — add it above the `struct LichessClient` definition in `backend/src/lichess/client.rs`. `reqwest::Client` and `String` are both `Clone`, so this is a straightforward derive with no further changes needed.

- [ ] **Step 3: Call `spawn_streams` once the token is verified**

In `handle_save_token` (Task 8's code), after `self.client = Some(client);`, add:

```rust
self.spawn_streams(replier.clone());
```

- [ ] **Step 4: Build and run the existing test suite**

Run: `cd backend && cargo build && cargo test`
Expected: still all passing — this exercises Step 1's addition to `client.rs` (an always-on module) along with everything from Tasks 2–8. It does **not** exercise Step 2/3's changes to `backend_app.rs`, which stay unverifiable on this machine for the same reason as Task 8's `backend_app.rs` work (transport-gated, needs Linux). Note in your report that the streaming-loop wiring itself is unverified until Task 14's on-device pass.

- [ ] **Step 5: Commit**

```bash
git add backend/Cargo.toml backend/src/lichess/client.rs backend/src/backend_app.rs
git commit -m "Add background streaming loop for account events and per-game state"
```

---

### Task 10: AppLoad manifest and QML app shell

**Files:**
- Create: `frontend/manifest.json`
- Create: `frontend/application.qrc`
- Create: `frontend/ui/main.qml`

**Interfaces:**
- Produces: the root QML file that owns the `AppLoad` endpoint and switches between the four screens built in Tasks 11–13 by listening for `BackendMessage` types.

- [ ] **Step 1: Write `frontend/manifest.json`**

```json
{
    "name": "Lichess",
    "loadsBackend": true,
    "entry": "/ui/main.qml",
    "id": "remarkable-lichess",
    "supportsScaling": false,
    "canHaveMultipleFrontends": false
}
```

- [ ] **Step 2: Write `frontend/application.qrc`**

```xml
<RCC>
    <qresource prefix="/">
        <file>ui/main.qml</file>
        <file>ui/SetupScreen.qml</file>
        <file>ui/HomeScreen.qml</file>
        <file>ui/SeekScreen.qml</file>
        <file>ui/BoardScreen.qml</file>
        <file>ui/BoardSquare.qml</file>
    </qresource>
</RCC>
```

- [ ] **Step 3: Write `frontend/ui/main.qml`**

```qml
import QtQuick 2.5
import QtQuick.Controls 2.5
import net.asivery.AppLoad 1.0

Rectangle {
    anchors.fill: parent
    color: "white"

    property bool hasToken: false

    AppLoad {
        id: endpoint
        applicationID: "remarkable-lichess"
        onMessageReceived: (type, contents) => {
            var msg = JSON.parse(contents)
            if (msg.type === "TokenVerified") {
                hasToken = true
                endpoint.sendMessage(1, JSON.stringify({type: "RequestHome"}))
                screenLoader.source = "HomeScreen.qml"
            } else if (msg.type === "TokenInvalid") {
                hasToken = false
                screenLoader.source = "SetupScreen.qml"
            } else if (msg.type === "HomeState" || msg.type === "SeekCreated" || msg.type === "ChallengeCreated") {
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "BoardState" || msg.type === "GameOver" || msg.type === "MoveRejected" || msg.type === "Reconnecting") {
                if (screenLoader.source.toString().indexOf("BoardScreen") === -1) {
                    screenLoader.source = "BoardScreen.qml"
                }
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            }
        }
    }

    function sendToBackend(obj) {
        endpoint.sendMessage(1, JSON.stringify(obj))
    }

    Loader {
        id: screenLoader
        anchors.fill: parent
        source: "SetupScreen.qml"
        onLoaded: {
            if (item.hasOwnProperty("backendSender")) {
                item.backendSender = sendToBackend
            }
        }
    }
}
```

- [ ] **Step 4: Verify the QML parses via the on-PC build**

Follow `rm-appload`'s documented on-PC compilation approach (`qmake6 .` then `make`, per its README) against a placeholder copy of the example app's `.pro`/build setup, substituting this app's `application.qrc` and `ui/main.qml`. Since `SetupScreen.qml` etc. don't exist yet, this step will fail to load them at runtime — that's expected until Tasks 11–13 are done. Confirm instead that `main.qml` itself has no syntax errors:

Run: `qmlformat frontend/ui/main.qml`
Expected: prints the reformatted file with no parse errors (if `qmlformat` isn't installed, `qmllint frontend/ui/main.qml` from the same Qt toolchain is an acceptable substitute).

- [ ] **Step 5: Commit**

```bash
git add frontend/manifest.json frontend/application.qrc frontend/ui/main.qml
git commit -m "Add AppLoad manifest and QML app shell with screen routing"
```

---

### Task 11: Setup and Home screens

**Files:**
- Create: `frontend/ui/SetupScreen.qml`
- Create: `frontend/ui/HomeScreen.qml`
- Modify: `frontend/application.qrc` (already lists both — no change needed if Task 10 was followed exactly)

**Interfaces:**
- Consumes: `backendSender` property (a JS function set by `main.qml`'s `Loader.onLoaded`, per Task 10) for sending `SaveToken` / `RequestHome` messages.
- Produces: a `handleMessage(msg)` function on each screen's root item, called by `main.qml` when a relevant `BackendMessage` arrives.

- [ ] **Step 1: Write `frontend/ui/SetupScreen.qml`**

```qml
import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    anchors.fill: parent
    color: "white"
    property var backendSender

    Column {
        anchors.centerIn: parent
        spacing: 24
        width: parent.width * 0.8

        Text {
            text: "Enter your Lichess personal API token"
            font.pixelSize: 32
            wrapMode: Text.WordWrap
            width: parent.width
        }

        TextField {
            id: tokenField
            width: parent.width
            font.pixelSize: 28
            placeholderText: "lip_..."
        }

        Text {
            id: errorText
            color: "black"
            font.pixelSize: 24
            visible: text.length > 0
        }

        Button {
            text: "Save"
            onClicked: {
                errorText.text = ""
                backendSender({type: "SaveToken", token: tokenField.text})
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "TokenInvalid") {
            errorText.text = "Token rejected: " + msg.reason
        }
    }
}
```

- [ ] **Step 2: Write `frontend/ui/HomeScreen.qml`**

```qml
import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    anchors.fill: parent
    color: "white"
    property var backendSender
    property string resumableGameId: ""

    Column {
        anchors.centerIn: parent
        spacing: 24

        Text {
            text: "Lichess"
            font.pixelSize: 48
        }

        Button {
            text: "Resume game"
            visible: resumableGameId.length > 0
            onClicked: {
                // The board screen is driven purely by incoming BoardState/GameOver
                // messages (Task 10's router), so resuming just means switching screens
                // and letting the already-running per-game stream (Task 9) deliver state.
                parent.parent.parent.screenLoader.source = "BoardScreen.qml"
            }
        }

        Button {
            text: "New game"
            onClicked: {
                parent.parent.parent.screenLoader.source = "SeekScreen.qml"
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "HomeState") {
            resumableGameId = msg.resumable_game_id || ""
        }
    }
}
```

Note: `parent.parent.parent.screenLoader` is a fragile relative path from a `Loader`-loaded item back up to `main.qml`'s `Loader` id. Confirm the exact depth against the real object tree once Task 10's `main.qml` is running (add `id: root` to the top-level `Rectangle` in `main.qml` and reference `root.screenLoader` from child screens instead, via `Loader.item`'s access to the parent context — QML's `Connections`/context properties are the cleaner mechanism here). Treat this as the one piece of this task most likely to need adjustment once run on-device; the message-passing logic (`handleMessage`, `backendSender`) is the tested, load-bearing part.

- [ ] **Step 3: Verify QML syntax**

Run: `qmlformat frontend/ui/SetupScreen.qml frontend/ui/HomeScreen.qml`
Expected: both reformat with no parse errors.

- [ ] **Step 4: Commit**

```bash
git add frontend/ui/SetupScreen.qml frontend/ui/HomeScreen.qml
git commit -m "Add Setup and Home screens"
```

---

### Task 12: Seek/Challenge screen

**Files:**
- Create: `frontend/ui/SeekScreen.qml`

**Interfaces:**
- Consumes: `backendSender` (as above) for `CreateSeek` / `CreateChallenge` messages.
- Produces: `handleMessage(msg)` reacting to `SeekCreated` / `ChallengeCreated` by switching to `BoardScreen.qml`.

- [ ] **Step 1: Write `frontend/ui/SeekScreen.qml`**

```qml
import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    anchors.fill: parent
    color: "white"
    property var backendSender

    Column {
        anchors.centerIn: parent
        spacing: 24
        width: parent.width * 0.8

        Text { text: "New rapid game"; font.pixelSize: 40 }

        Row {
            spacing: 16
            Text { text: "Minutes:"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter }
            TextField { id: minutesField; text: "10"; font.pixelSize: 24; width: 80 }
            Text { text: "Increment:"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter }
            TextField { id: incrementField; text: "0"; font.pixelSize: 24; width: 80 }
        }

        Button {
            text: "Open seek (auto-pair)"
            onClicked: backendSender({
                type: "CreateSeek",
                minutes: parseInt(minutesField.text),
                increment: parseInt(incrementField.text)
            })
        }

        Row {
            spacing: 16
            TextField { id: usernameField; font.pixelSize: 24; placeholderText: "opponent username"; width: 240 }
            Button {
                text: "Challenge"
                onClicked: backendSender({
                    type: "CreateChallenge",
                    username: usernameField.text,
                    minutes: parseInt(minutesField.text),
                    increment: parseInt(incrementField.text)
                })
            }
        }
    }

    function handleMessage(msg) {
        // SeekCreated / ChallengeCreated are informational only in v1 — the actual
        // transition to BoardScreen happens when main.qml's router (Task 10) sees the
        // first BoardState message arrive from the background game stream (Task 9).
    }
}
```

- [ ] **Step 2: Verify QML syntax**

Run: `qmlformat frontend/ui/SeekScreen.qml`
Expected: reformats with no parse errors.

- [ ] **Step 3: Commit**

```bash
git add frontend/ui/SeekScreen.qml
git commit -m "Add Seek/Challenge screen"
```

---

### Task 13: Board screen

**Files:**
- Create: `frontend/ui/BoardSquare.qml`
- Create: `frontend/ui/BoardScreen.qml`

**Interfaces:**
- Consumes: `backendSender` for `MakeMove` / `Resign`; receives `BoardState` / `GameOver` / `MoveRejected` / `Reconnecting` via `handleMessage`.
- Produces: the actual playable board — the core deliverable of the whole project.

- [ ] **Step 1: Write `frontend/ui/BoardSquare.qml`**

```qml
import QtQuick 2.5

Rectangle {
    id: square
    property string squareName: ""
    property string pieceGlyph: ""
    property bool isLight: true
    property bool isHighlighted: false
    signal tapped(string squareName)

    color: isHighlighted ? "#a0c8a0" : (isLight ? "#e8e0d0" : "#8a7f6a")

    Text {
        anchors.centerIn: parent
        text: pieceGlyph
        font.pixelSize: parent.height * 0.6
    }

    MouseArea {
        anchors.fill: parent
        onClicked: square.tapped(square.squareName)
    }
}
```

- [ ] **Step 2: Write `frontend/ui/BoardScreen.qml`**

```qml
import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: boardScreen
    anchors.fill: parent
    color: "white"
    property var backendSender

    property string fen: ""
    property string turn: "white"
    property int whiteTimeMs: 0
    property int blackTimeMs: 0
    property var legalMoves: []
    property string selectedSquare: ""
    property string statusText: ""

    function filesRanks() {
        var files = ["a","b","c","d","e","f","g","h"]
        var ranks = ["8","7","6","5","4","3","2","1"]
        return {files: files, ranks: ranks}
    }

    function pieceAt(squareName) {
        // Minimal FEN board decode: walk the piece-placement field only.
        var placement = fen.split(" ")[0]
        var rows = placement.split("/")
        var fr = filesRanks()
        var rankIndex = fr.ranks.indexOf(squareName[1])
        var fileIndex = fr.files.indexOf(squareName[0])
        if (rankIndex < 0 || fileIndex < 0) return ""
        var row = rows[rankIndex]
        var col = 0
        for (var i = 0; i < row.length; i++) {
            var c = row[i]
            if (c >= '1' && c <= '8') {
                col += parseInt(c)
            } else {
                if (col === fileIndex) return c
                col += 1
            }
        }
        return ""
    }

    function glyphFor(pieceChar) {
        var map = {
            "K": "♔", "Q": "♕", "R": "♖", "B": "♗", "N": "♘", "P": "♙",
            "k": "♚", "q": "♛", "r": "♜", "b": "♝", "n": "♞", "p": "♟"
        }
        return map[pieceChar] || ""
    }

    function destinationsFrom(square) {
        var out = []
        for (var i = 0; i < legalMoves.length; i++) {
            if (legalMoves[i].from === square) out.push(legalMoves[i].to)
        }
        return out
    }

    function onSquareTapped(squareName) {
        if (selectedSquare === "") {
            if (pieceAt(squareName) !== "") selectedSquare = squareName
            return
        }
        if (selectedSquare === squareName) {
            selectedSquare = ""
            return
        }
        var dests = destinationsFrom(selectedSquare)
        if (dests.indexOf(squareName) !== -1) {
            var promo = null
            for (var i = 0; i < legalMoves.length; i++) {
                if (legalMoves[i].from === selectedSquare && legalMoves[i].to === squareName && legalMoves[i].promotion) {
                    promo = legalMoves[i].promotion
                }
            }
            backendSender({type: "MakeMove", from: selectedSquare, to: squareName, promotion: promo})
            selectedSquare = ""
        } else {
            selectedSquare = pieceAt(squareName) !== "" ? squareName : ""
        }
    }

    Column {
        anchors.fill: parent
        spacing: 8

        Text {
            text: "Black: " + Math.floor(blackTimeMs / 1000) + "s"
            font.pixelSize: 28
        }

        Grid {
            id: grid
            columns: 8
            rows: 8
            width: Math.min(boardScreen.width, boardScreen.height - 160)
            height: width

            Repeater {
                model: 64
                BoardSquare {
                    width: grid.width / 8
                    height: grid.height / 8
                    property int fileIdx: index % 8
                    property int rankIdx: Math.floor(index / 8)
                    squareName: filesRanks().files[fileIdx] + filesRanks().ranks[rankIdx]
                    isLight: (fileIdx + rankIdx) % 2 === 0
                    pieceGlyph: glyphFor(pieceAt(squareName))
                    isHighlighted: selectedSquare === squareName || destinationsFrom(selectedSquare).indexOf(squareName) !== -1
                    onTapped: onSquareTapped(squareName)
                }
            }
        }

        Text {
            text: "White: " + Math.floor(whiteTimeMs / 1000) + "s"
            font.pixelSize: 28
        }

        Text {
            text: statusText
            font.pixelSize: 24
        }

        Button {
            text: "Resign"
            onClicked: backendSender({type: "Resign"})
        }
    }

    function handleMessage(msg) {
        if (msg.type === "BoardState") {
            fen = msg.fen
            turn = msg.turn
            whiteTimeMs = msg.white_time_ms
            blackTimeMs = msg.black_time_ms
            legalMoves = msg.legal_moves
            statusText = ""
        } else if (msg.type === "GameOver") {
            statusText = "Game over: " + msg.result + " (" + msg.reason + ")"
        } else if (msg.type === "MoveRejected") {
            statusText = "Move rejected: " + msg.reason
            selectedSquare = ""
        } else if (msg.type === "Reconnecting") {
            statusText = "Reconnecting..."
        }
    }
}
```

Note: the FEN decode in `pieceAt` handles piece placement only (not castling rights, en passant, etc.) — that's correct, since the board only needs to know *where pieces are*, and the backend (Task 6/7) is the sole source of truth for legality. Promotion is currently limited to whatever a single `legalMoves` entry's `promotion` field carries (queen by default from `shakmaty`'s move ordering) — a full promotion-piece picker (letting the player choose queen/rook/bishop/knight) is a reasonable v1.1 addition once basic play is confirmed working end-to-end in Task 14; note this explicitly rather than silently shipping queen-only promotion as if it were a deliberate design choice.

- [ ] **Step 3: Verify QML syntax**

Run: `qmlformat frontend/ui/BoardSquare.qml frontend/ui/BoardScreen.qml`
Expected: both reformat with no parse errors.

- [ ] **Step 4: Commit**

```bash
git add frontend/ui/BoardSquare.qml frontend/ui/BoardScreen.qml
git commit -m "Add board screen with tap-to-move and legal-move highlighting"
```

---

### Task 14: Build, deploy, and end-to-end device verification

**Files:**
- Create: `scripts/build-rm.sh`
- Create: `scripts/deploy.sh`

**Interfaces:**
- Produces: a deployable app bundle at `dist/remarkable-lichess/` and a one-command deploy to the tablet.

- [ ] **Step 1: Write `scripts/build-rm.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

# Cross-compile the Rust backend for the Paper Pro Move's aarch64 target,
# following the same Cross.toml-based approach chessmarkable uses for this
# device family. Adjust the target triple if `cross` reports a mismatch for
# your specific rm-appload toolchain image.
cd "$(dirname "$0")/../backend"
# --features transport is required here: the bin target (and backend_app.rs)
# are gated behind it since they depend on appload-client (see Global Constraints
# and Task 1) — this is the first point in the whole plan where that feature is
# actually compiled, since the dev machine used for Tasks 1-9 had no Linux target.
cross build --release --target aarch64-unknown-linux-gnu --features transport --bin backend

mkdir -p ../dist/remarkable-lichess
cp target/aarch64-unknown-linux-gnu/release/backend ../dist/remarkable-lichess/backend

cd ../frontend
cp manifest.json ../dist/remarkable-lichess/manifest.json
# QML resource compilation (rcc) follows rm-appload's own example build
# scripts (build-rm.sh / build-rmpp.sh in examples/appload/full/) — copy the
# exact rcc invocation from whichever of those matches this device's XOVI
# version once confirmed in Task 14 Step 3, rather than guessing the flags here.
cp -r ui ../dist/remarkable-lichess/ui
```

- [ ] **Step 2: Write `scripts/deploy.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail

TABLET_HOST="${TABLET_HOST:-10.11.99.1}"
APP_DIR="/home/root/xovi/exthome/appload/remarkable-lichess"

ssh "root@${TABLET_HOST}" "mkdir -p '${APP_DIR}'"
scp -r dist/remarkable-lichess/* "root@${TABLET_HOST}:${APP_DIR}/"
echo "Deployed to ${TABLET_HOST}:${APP_DIR} — relaunch AppLoad on the tablet to pick it up."
```

- [ ] **Step 3: Make both scripts executable and commit**

```bash
chmod +x scripts/build-rm.sh scripts/deploy.sh
git add scripts/build-rm.sh scripts/deploy.sh
git commit -m "Add build and deploy scripts for the Paper Pro Move"
```

- [ ] **Step 4: Manual end-to-end verification on-device**

This is the spec's "definition of v1 done" — run through it directly on the tablet, not simulated:

1. Run `./scripts/build-rm.sh && ./scripts/deploy.sh` (tablet connected via USB, reachable at `10.11.99.1`, AppLoad already installed via reManager per the design spec's deployment section).
2. Launch "Lichess" from the AppLoad sidebar. Confirm the Setup screen appears.
3. Paste a real Lichess personal API token (scope `board:play`, from lichess.org account settings). Confirm it transitions to Home on success, and shows an inline error on an intentionally-wrong token.
4. From Home, start a new game via "Open seek" at 10+0 against a second Lichess account (a throwaway alt account is fine).
5. From the second account (phone/browser), accept/join the seek. Confirm the tablet transitions to the board automatically once the game starts, without any manual refresh.
6. Play moves from both sides (alternating input from the tablet and the second account) until at least one pawn promotes. Confirm: legal-square highlighting matches actual legal moves, the clock display counts down correctly for the side to move, and opponent moves from the second account appear on the tablet without needing to back out and re-enter the screen.
7. Resign or play to checkmate. Confirm the "Game over" state displays and the app returns to Home cleanly.
8. Kill and relaunch the AppLoad app mid-game (a second time, on a fresh game) to confirm the "app closed mid-game" recovery path from the spec: reopening should resync via Home's resumable-game check and drop back into the same board.

If any step fails, treat it as a bug against the relevant task above (e.g. a `BoardState` field mismatch is a Task 3/7 issue; a screen-routing glitch is a Task 10/11 issue) rather than a new undocumented feature — fix forward in the existing module boundaries established by this plan.

---

## Self-Review Notes

- **Spec coverage:** all four QML screens, the backend's Lichess client + rules engine + IPC protocol, casual-only seeks/challenges, no-background-notification behavior (the app only streams while its `LichessBackend` process is alive, which AppLoad only runs while the app is foregrounded), and the deployment path are each covered by a task above.
- **Fixed during review:** Task 8 initially omitted `create_seek`/`create_challenge` implementations that Task 5's interface promised — added inline as part of Task 8 Step 1 rather than silently leaving them missing.
- **Known follow-ups flagged explicitly in-place (not silently deferred):** the `HomeScreen.qml` relative-parent screen navigation path (Task 11), the simplified non-buffering line-splitting in `stream_lines` (Task 9), and queen-only promotion pending a real picker UI (Task 13) are each called out with a concrete note on what to verify or build next, rather than left as unmarked gaps.
- **Fixed after Task 1's implementer surfaced a real environment constraint:** the dev machine has no Linux target and no `cross`/Docker, and `appload-client` only compiles on Linux. Task 1's implementer initially worked around this by vendoring and hand-patching a local clone of `rm-appload` outside git tracking — unreproducible for anyone else building this repo, including later tasks' own cross-compilation step. Fixed by restructuring the backend into a `[lib]` (no `appload-client` dependency, always compiled/tested) plus a `transport`-feature-gated `[[bin]]` and `backend_app` module (only compiled with real Linux cross-compilation, in Task 14). This is reflected in the Global Constraints, File Structure, and Tasks 1/2/3/6/8/9/14 above — Task 1 needs to be re-implemented against the corrected brief before continuing.
