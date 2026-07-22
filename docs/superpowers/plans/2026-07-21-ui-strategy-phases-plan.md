# UI strategy backlog: phased implementation plan

Implements the prioritized backlog from `docs/ui-strategy-2026-07-21.md` (P0-P3
there; P2.5/P5 stay deferred, see that doc's own reasoning -- P2.5 needs a
confirmed haptic motor on the target hardware first, P5 is a from-scratch
design pass, not a backlog item). Each phase is independently shippable and
independently testable; do them in order, verifying `cargo test` after every
backend-touching phase (this sandbox now has a working `rustup`-installed
toolchain -- run with `CARGO_TARGET_DIR=/tmp/backend-target cargo test` from
`backend/`, since the mounted project folder itself rejects the temp-file
renames Cargo's own build process needs).

QML has no available toolchain in this dev environment (no Qt/QML tools at
all, same constraint the original client plan hit for every QML task) -- every
QML change here is verified by careful inspection against this project's own
established patterns, not compiled/run, exactly as the original plan's Task
14 note describes.

## Phase 1 (P0): Game review move-by-move navigation

Already fully designed in
`docs/superpowers/specs/2026-07-21-game-review-move-navigation-design.md` --
implement it as speced. Summary: `GET /api/game/export/{id}` (JSON) returns a
space-separated **SAN** move string (confirmed against
`lichess-org/api`'s `games-exportOneGame.json.yaml` example -- e.g.
`"moves": "d4 d5 c4 c6 Nc3 ..."`, not UCI); replay it once via `shakmaty`'s
`SanPlus`/`San::to_move` (already a dependency; `game/rules.rs`'s existing
UCI-based replay helpers don't apply here since the export format is SAN, not
UCI) to build a FEN snapshot after every ply.

**Files:**
- New `backend/src/game/replay.rs`: `fens_for_moves(moves: &[String]) ->
  Result<Vec<String>>`, pure/stateless, starts from the standard start
  position (no Chess960/`initialFen` support -- out of scope per the spec).
- `backend/src/lichess/models.rs`: new `GameExport { moves: String }` (only
  the field this needs, matching this file's existing "only model what's
  used" convention).
- `backend/src/lichess/client.rs`: new `export_game(game_id: &str) ->
  Result<GameExport>` -- GET `/api/game/export/{id}` with `Accept:
  application/json` (default is PGN text, same footgun `get_game_history`
  already works around for a different endpoint).
- `backend/src/protocol.rs`: `FrontendMessage::RequestGameMoves { game_id }`,
  `BackendMessage::GameMoves { moves: Vec<String>, fens: Vec<String> }`.
- `backend/src/backend_app.rs`: `handle_request_game_moves`.
- `frontend/ui/GameHistoryScreen.qml`: rows become tappable (send
  `RequestGameMoves`, navigate to `GameReviewScreen.qml`).
- New `frontend/ui/GameReviewScreen.qml`: read-only board reusing
  `BoardSquare`, Prev/Next, tappable move list, driven by pure array indexing
  into `fens` (no chess logic client-side).

**Verify:** `cargo test` (new `game::replay` unit tests against known short
SAN sequences, new `lichess::client` wiremock test for `export_game`).

## Phase 2 (P1): Rating change after a rated game ends

**Correction to the original strategy doc's own first-draft assumption,**
found by cloning `lichess-org/api` and reading the actual schema files rather
than trusting the changelog PR summary alone: `ratingDiff` is **not** a field
on `GameStateEvent` (the per-game `/api/board/game/stream/{id}` stream this
app's `GameSession`/`BoardScreen` already consume for live board state --
confirmed by reading `doc/specs/schemas/GameStateEvent.yaml` directly, it has
no such field). It's on `GameEventInfo` (`doc/specs/schemas/GameEventInfo.yaml`),
which is the payload of the **account-wide** event stream's (`/api/stream/event`,
already open in this app via `spawn_streams`) `gameFinish` event -- a
different stream this app already has open for `gameStart`/challenge events,
but currently ignores `gameFinish` entirely (`_ => {}` in `spawn_streams`'s
match). So this phase is "start listening to an event this stream already
delivers," not "add a field to an existing message."

**Files:**
- `backend/src/lichess/models.rs`: new `GameFinishInfo { id: String,
  #[serde(default)] rating_diff: Option<i32> }` (serde-renamed from
  `ratingDiff`; `#[serde(default)]` since casual games omit it entirely, per
  the schema). Change `EventStreamMessage::GameFinish { game: EventGame }` to
  `GameFinish { game: GameFinishInfo }` -- `EventGame` (bare `{id}`) stays as
  today for `GameStart`, untouched.
- `backend/src/protocol.rs`: new `BackendMessage::RatingDiff { rating_diff:
  i32 }`. Deliberately no `game_id` in the wire message -- filtered
  server-side against the currently-tracked session, matching this codebase's
  existing convention of relativizing/filtering server-side rather than
  pushing raw data at the frontend (see `draw_offered_by_opponent` etc.).
- `backend/src/backend_app.rs`: in `spawn_streams`'s match, add a
  `GameFinish { game }` arm: lock `session_handle`, compare `game.id` against
  the tracked session's `game_id` (best-effort -- if a new game already
  started and replaced the session, drop it silently, same "not exhaustive,
  server is still authoritative" posture as the `Abort` button's own
  comment), and if it matches and `rating_diff` is `Some`, send
  `BackendMessage::RatingDiff`.
- `frontend/ui/BoardScreen.qml`: handle `RatingDiff` -- append
  `"  (" + (diff > 0 ? "+" : "") + diff + ")"` to `statusText` if a
  "Game over" status is already showing (the common case: the per-game
  stream's terminal `GameState` update, which drives today's `GameOver`
  message, and the account stream's `gameFinish` are two independent signals
  that arrive close together but in no guaranteed order); otherwise cache it
  in a new `pendingRatingDiffText` property for the `GameOver` handler to
  append if it arrives second.

**Verify:** `cargo test` (new `lichess::models` parse test for `gameFinish`
with and without `ratingDiff`; new `protocol` round-trip test for
`RatingDiff`).

## Phase 3 (P2): Move confirmation setting

Confirmed real and shipped in the official `lichess-org/mobile` app (cloned
and read `lib/src/model/game/game_controller.dart`'s `moveToConfirm`/
`confirmMove()`/`cancelMove()`), default **off** there too (see
`ui-strategy-2026-07-21.md`'s P2 for the full citation trail). This app
already has the right shape in-house: the two-tap "arm" pattern used for
`Resign`/`LogOut`. Generalize that into a proper pending-move slot (not a
second identical tap, since the whole point here is a legible Confirm/Cancel
choice, matching lichess's own UX) rather than reusing the exact same
boolean-arm mechanic verbatim.

**Files:**
- `backend/src/settings.rs`: add `move_confirmation: bool` to `AppSettings`
  (defaults to `false`, same pattern as `auto_queen_promotion`).
- `backend/src/protocol.rs`: add `move_confirmation: bool` to
  `SaveSettings`/`SettingsState`.
- `backend/src/backend_app.rs`: thread the new field through
  `handle_request_settings`/`handle_save_settings` (mirrors
  `auto_queen_promotion` exactly).
- `frontend/ui/SettingsScreen.qml`: new toggle button under "Gameplay",
  same shape as the existing auto-queen-promotion button.
- `frontend/ui/main.qml`: push/re-sync `moveConfirmation` the same way
  `autoQueenPromotion` already is (`onXChanged` re-sync into the loaded
  screen, `setMoveConfirmation` sender function).
- `frontend/ui/BoardScreen.qml`: when `moveConfirmation` is on, a legal
  tap-to-destination sets `pendingMoveConfirmation = {from, to, promotion}`
  instead of sending `MakeMove` immediately (promotion picker, if any, still
  resolves first -- confirmation is the last gate before the network call,
  same order lichess mobile uses). Show a Confirm/Cancel row (reusing the
  promotion popup's modal styling) while pending; Confirm sends `MakeMove`,
  Cancel clears `selectedSquare`/`pendingMoveConfirmation` with no network
  call.

**Verify:** `cargo test` (settings round-trip + protocol round-trip tests,
same shape as the existing `auto_queen_promotion` tests).

## Phase 4 (P3): Low-time visual warning

Threshold matches the official mobile app's own logic (confirmed via
`lichess-org/mobile` issue #785, not invented): 1/8 of the side's total time
control, clamped to [10s, 60s]. **Visual only** -- no sound (no confirmed
speaker on this reMarkable hardware family) and no local ticking Timer (this
app deliberately shows the clock only as of the last authoritative
`BoardState`, see `BoardScreen.qml`'s own comment on the e-ink-redraw-cost
tradeoff). This costs zero extra redraws: the color check only runs inside a
redraw that a real `BoardState` update was already causing.

**Files:**
- `frontend/ui/BoardScreen.qml` only, no backend change: a
  `function isLowTime(ms, totalMs)` helper (`ms < Math.min(60000,
  Math.max(10000, totalMs / 8))`); needs each side's *initial* clock alongside
  the live one to compute the 1/8 threshold correctly (`whiteTimeMs`/
  `blackTimeMs` alone aren't enough once time has already elapsed) --
  `BackendMessage::BoardState` doesn't currently carry the initial clock
  either, so this phase also threads `initial_clock_ms: u64` through
  `GameState`/`BoardState` (parsed once from `GameFull.clock.initial`,
  cached on `GameSession` for the game's lifetime next to `opponent_name`,
  not re-derived every update). Clock `Text` elements' `color` binding adds
  the low-time check alongside the existing `darkMode` branch.

**Verify:** `cargo test` for the new `initial_clock_ms` plumbing (round-trip
through `GameSession`/`BoardState`, same style as `opponent_rating`); the
`isLowTime` QML helper itself is simple enough to verify by inspection only
(pure arithmetic, no chess logic).

## Deferred, not part of this plan (see `ui-strategy-2026-07-21.md`)

- **P2.5 haptic feedback** -- blocked on confirming this reMarkable hardware
  family actually has a haptic motor; don't build blind.
- **P5 pen-drawn annotation** -- a real opportunity, but its own design pass,
  not a backlog item sized like the four above.
