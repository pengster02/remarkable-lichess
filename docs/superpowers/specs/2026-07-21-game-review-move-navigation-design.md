# Game review: move-by-move navigation

## Problem

Game History currently shows a filterable list of past games (opponent, result,
speed, opening) with no way to see how the game was actually played. There's
no way to open a finished game and step through its moves.

## Scope

Finished (completed) games only, opened from Game History. The live
in-progress game already shows its own move list as it happens (BoardScreen's
`moveHistory`) and is out of scope here.

Per how Lichess itself treats this: a finished-game review is a **linear**
move list, not a branching move tree. Move trees/variations (parenthesized
sidelines) are an analysis-board/study concept for exploring alternatives with
an engine, not something a plain post-game review needs. No variation/branch
UI is built here.

## Design

### Data flow

1. Frontend sends a new `FrontendMessage::RequestGameMoves { game_id }` when
   the user taps a game row in `GameHistoryScreen`.
2. Backend fetches that single game from Lichess (`GET /api/game/export/{id}`,
   JSON), which returns (among other fields) a space-separated SAN move
   string.
3. Backend replays those moves once through `shakmaty` (already a dependency,
   already used for the live board's rules/legality) to build a FEN snapshot
   after every ply.
4. Backend replies once with a new
   `BackendMessage::GameMoves { moves: Vec<String>, fens: Vec<String> }`,
   where `fens[0]` is the starting position and `fens[i]` is the position
   after SAN move `moves[i-1]` (so `fens.len() == moves.len() + 1`).
5. Frontend navigates to a new `GameReviewScreen.qml` and drives Prev/Next and
   tap-a-move purely by indexing into the already-computed `fens` array — no
   chess logic in the frontend at all.

This mirrors how Lichess's own analysis board works: replay/compute once when
the game loads, cache the position at each node, and make navigation an O(1)
lookup rather than a re-simulation or a network round-trip per step.

### Components

- `backend/src/game/replay.rs` (new): one function,
  `pub fn fens_for_moves(moves: &[String]) -> Result<Vec<String>>`. Kept
  separate from `game/session.rs`, which models live, mutable game state —
  this is a stateless pure replay of a fixed, already-finished move list.
- `backend/src/lichess/client.rs`: new method `export_game(game_id: &str) ->
  Result<GameExport>` (or similar), following the existing per-endpoint method
  pattern (bearer auth, `error_from_response` on non-2xx, logged via
  `send_logged` like every other method in this file).
- `backend/src/lichess/models.rs`: new `GameExport` struct modeling just the
  `moves` field needed (matching this file's existing pattern of only
  modeling fields actually used).
- `backend/src/backend_app.rs`: new `handle_request_game_moves` following the
  existing handler pattern (`Some(client) = ... else { TokenInvalid }`, then
  call client, map `Err` to `ErrorMsg`).
- `backend/src/protocol.rs`: add `RequestGameMoves`/`GameMoves` to the
  existing `FrontendMessage`/`BackendMessage` enums.
- `frontend/ui/GameHistoryScreen.qml`: game rows become tappable, sending
  `RequestGameMoves` and navigating (via the existing `navigateTo` pattern
  used elsewhere) to `GameReviewScreen`.
- `frontend/ui/GameReviewScreen.qml` (new): reuses the existing `BoardSquare`
  grid layout for visual consistency with `BoardScreen`, but read-only (no
  `onTapped` move-making, no legal-move highlighting, no clock). Shows:
  - the board at `fens[currentIndex]`
  - Prev/Next buttons (disabled at the two ends)
  - the formatted move list (reusing the "1. e4 e5  2. Nf3 Nc6" style already
    established in `BoardScreen.formattedMoveHistory()`), with each move
    tappable to jump `currentIndex` directly to it

### Error handling

Reuses the existing `ErrorMsg` message — if the Lichess export call or the
replay fails (e.g. a move fails to parse/apply), the backend sends `ErrorMsg`
and the frontend shows it, staying on Game History rather than navigating to
a broken review screen.

### Testing

- `lichess::client`: a new wiremock-based test for `export_game`, matching the
  existing tests' style in `client.rs` (mock server, assert request
  path/headers, assert parsed response).
- `game::replay`: unit tests asserting `fens_for_moves` against known short
  move sequences (e.g. `["e4", "e5", "Nf3"]`) produce the expected FEN at each
  step, matching `GameSession`'s existing test style for chess-logic
  assertions.
- No QML test framework exists in this repo; the frontend side is verified
  manually on-device, as with every other screen in this app.

## Out of scope

- Variations/branching move trees (analysis-board-only concept, not needed
  for finished-game review).
- Any engine analysis/evaluation.
- Reviewing the live in-progress game's own move history (already handled by
  `BoardScreen`).
