# reMarkable Lichess Client — Design

**Date:** 2026-07-17
**Target device:** reMarkable Paper Pro Move (1696×954, 16:9 color E Ink), reMarkable OS in the Vellum/AppLoad-compatible range (3.26.x–3.27.x after downgrade from 3.28)
**Status:** Approved for planning

## Purpose

Play real-time Lichess games (rapid time controls: 10+0, 15+10, etc.) directly on the tablet — no existing project does this. Nobody has built a reMarkable Lichess client before (confirmed: zero GitHub repos matching "remarkable lichess", no mentions in the `lichess` GitHub topic, no hits in chessmarkable's issue tracker or the awesome-reMarkable list). Chess.com is explicitly out of scope — its public API is read-only and gates live-play access behind partnership deals it won't grant to an individual.

## Non-goals (v1)

- Chess.com support (API doesn't allow it).
- Background/turn notifications — app only acts while it's the foreground AppLoad app.
- Bullet or other sub-3-minute time controls — flagged upfront as a poor fit for e-ink refresh latency; not designed for.
- Puzzles, analysis, spectating, correspondence games.
- Multi-user / login for anyone other than the device owner (single personal API token, no OAuth flow).

## Architecture

One AppLoad app, two isolated pieces communicating only over AppLoad's built-in message-passing protocol (`net.asivery.AppLoad`):

- **Frontend (QML):** pure UI. No chess logic, no networking. Renders screens, handles taps, requests actions from the backend, renders whatever `board_state` the backend last pushed.
- **Backend (single static Rust binary):** owns *all* Lichess networking and *all* chess-rules computation. The frontend never talks to Lichess directly.

Rationale: this is the platform's actively-maintained pattern (same one KOReader/rmstream use), QML's declarative layout adapts to the Move's actual screen dimensions (unlike chessmarkable's hardcoded reMarkable-2-era pixel layout), and Rust cross-compiles to this device's ARM target via a proven toolchain (`Cross.toml` + toltec-dev image, same as chessmarkable's own build).

## Components

### Backend (Rust), four modules in one binary

- **`lichess_client`** — Board API wrapper:
  - `POST /api/board/seek` — create an open seek at a chosen time control.
  - `POST /api/challenge/{username}` — challenge a specific player.
  - `GET /api/account/playing` — list current games (for Home screen resume).
  - `GET /api/stream/event` — account-level event stream (incoming challenges, `gameStart`).
  - `GET /api/board/game/stream/{gameId}` — per-game NDJSON stream (initial `gameFull`, then `gameState` on every move/clock update).
  - `POST /api/board/game/{gameId}/move/{move}` — submit a move (UCI).
  - Auth: personal API token (Bearer), scope `board:play`. No OAuth flow.

- **`rules`** — wraps `shakmaty` (established Rust chess-rules crate). On every position update, computes the **full legal-move list for every piece on the board**, not per-tap. This makes square-highlighting after a tap a pure local lookup with no network round-trip.

- **`session`** — holds the token (read from a config file written by the Setup screen), current game id, current position, current clocks.

- **`ipc`** — implements the AppLoad backend protocol: receives frontend messages (`select_square`, `make_move`, `create_seek`, `create_challenge`, `resign`, etc.) and emits frontend messages (`board_state`, `seek_created`, `game_over`, `move_rejected`, `error`, `reconnecting`).

- **Async runtime:** `tokio` event loop merging three sources into frontend updates: (1) the AppLoad IPC channel, (2) the account-level Lichess event stream, (3) the active game's NDJSON stream.

### Frontend (QML), four screens

1. **Setup** (first run only) — paste Lichess personal API token. Backend verifies via `GET /api/account`; error shown inline on failure, stays on this screen until a valid token is saved.
2. **Home** — shows a resumable in-progress game if `GET /api/account/playing` returns one, plus a "New Game" action.
3. **Seek/Challenge** — pick a rapid time control (10+0 / 15+10 / custom minutes+increment), then either "Open seek" (Lichess auto-pairs) or "Challenge user" (enter a username). Games are created casual/unrated by default in v1 — no rated toggle, to avoid the extra confirmation UI for a personal-use app.
4. **Board** — 8×8 grid, piece rendering, clock display for both sides, tap-to-select (highlights legal destinations from the cached `board_state.legalMoves` list) then tap-to-move, promotion piece picker when a pawn move reaches the last rank, resign action.

## Data flow

1. **First run:** token pasted → saved to config → backend calls `GET /api/account` to verify. Success → Home. Failure → error shown, stay on Setup.
2. **Home:** backend calls `GET /api/account/playing`. A game in progress → "Resume" shown alongside "New Game."
3. **New game:** user picks time control + seek-or-challenge → backend POSTs to the corresponding Lichess endpoint → backend waits on the account event stream for a `gameStart` event carrying the new game id → frontend transitions to Board.
4. **Board, every position change (yours or opponent's):** backend's per-game NDJSON stream delivers a `gameState` (or initial `gameFull`) event → backend replays the move via `shakmaty` to update its internal position → backend recomputes the full legal-move list for the new position → backend pushes one `board_state` message: `{ fen, clocks: {white, black}, turn, legalMoves: [{from, to, promotion?}], lastMove }`.
5. **Tap-to-move:** entirely frontend-local against the cached `legalMoves` list from step 4 — no backend round-trip just to highlight squares. Only a *completed* move (both taps done, promotion piece chosen if needed) sends `make_move {from, to, promotion?}` to the backend.
6. **Move submission:** backend translates the completed move to UCI, `POST`s to `/api/board/game/{gameId}/move/{move}`. The authoritative state update arrives back through the same NDJSON stream as any other move (step 4) — the app does not optimistically render the move ahead of that confirmation.
7. **Game end:** the per-game stream sends a terminal `gameState` (status ≠ `started`) → backend pushes `game_over {result, reason}` → frontend shows the result, returns to Home.

## Error handling

- **Invalid/expired token:** `GET /api/account` returns 401 → Setup screen shown again with an inline error.
- **Stream disconnect** (Wi-Fi hiccup, tablet slept mid-game): backend auto-reconnects with exponential backoff and resyncs current game state on reconnect. Frontend shows a small non-blocking "reconnecting…" indicator; no game state is lost.
- **Stale-cache move rejection** (rare race — opponent's move lands a moment before your tap completes): Lichess rejects the `move` POST → backend sends `move_rejected` → frontend discards its cached legal-move list and waits for the next authoritative `board_state` rather than trusting the stale one.
- **App closed mid-game:** expected, no special handling — reopening re-syncs via `GET /api/account/playing` (step 2) and returns to the same board.

## Testing

- **Backend:** zero reMarkable-specific dependencies, fully unit-testable off-device — canned NDJSON fixtures drive state-transition tests, reconnect/backoff tests, and `shakmaty` legal-move checks against known FEN positions.
- **IPC protocol:** tested via a small harness speaking the same AppLoad message format, without a real QML frontend running.
- **Frontend:** manual on-device testing; AppLoad supports on-PC compilation (`qmake6` per its README) for faster iteration than round-tripping to the tablet every time. No investment in automated UI testing for a personal project.
- **Definition of "v1 done":** play one complete real rapid game start-to-finish against a second account — covering seek creation, both sides moving, at least one promotion, and a clean game-over transition back to Home.

## Open items carried into planning (not blocking, but explicit)

- Exact AppLoad manifest fields/packaging steps for this app (will confirm against `rm-appload`'s example apps during implementation).
- Whether `shakmaty` needs any ARM-cross-compile-specific handling — expected to be fine (pure Rust, no C deps) but not yet verified on-device.
- Icon/visual asset creation for the board pieces — deferred to implementation, flat/minimal style suited to e-ink (no photorealistic pieces).
