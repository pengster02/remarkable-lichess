# Repo audit 2026-07-21: e-ink optimization + everything else

**Status (verified 2026-07-22): ALL findings below are closed.** Re-verified
item-by-item against the working tree: `cargo test --features transport` 111
pass / clippy clean (E2), NDJSON carry buffer + 3 regression tests (E1), key
gitignored (E3), seek/logout/finished-game stream handles all aborted
(E4-E6), `game_over_result` + tests (E7), all E8 nits fixed, scripts staged +
CARGO_TARGET_DIR-safe (F1-F3), Phases 2-4 QML halves shipped incl. the
settings-clobber fix (D1-D5), DisplayMethodArea wired on board grid / clocks
/ status / buttons (A), TextField.qml static cursor (B1), popup dim/
transitions off (B2), minimal-highlights setting end-to-end (B3), disabled
button state (B4), 256px pieces + sourceSize (B5), pieceMap/fr caching (C).
Remaining: on-device verification only — DisplayMethodArea is a stub in the
PC emulator, and the disabled-opacity/cursor rendering need a real-panel
look. Button/TextField staying non-darkMode-reactive is a known, documented
limitation, not an open finding.

Full-repo pass (all docs, all QML, all Rust, scripts). Backend verified by
running `cargo test` (97 pass) and `cargo clippy` (clean) — **but see E2: the
`--features transport` build the device actually ships is currently broken.**
QML findings by inspection (no Qt toolchain here, same as always).

## A. E-ink: the big one — `DisplayMethodArea` is still unused

`docs/remarkable-appload-platform-notes.md` §2 documented this in detail on
07-18; still zero references to `net.asivery.ApploadUtils` anywhere in
`frontend/`. Every redraw currently uses the default (`Content`) waveform.
Concrete wiring, highest value first:

1. **Board grid** (`BoardScreen.qml` `Grid#grid`, `GameReviewScreen.qml` same):
   wrap in `DisplayMethodArea { displayMethod: DisplayMethodArea.Fast }`.
   Selection/legal-dest highlights, last-move, check — all of it is transient
   state where speed beats fidelity. The pieces themselves are flat black/white
   line art that survives a fast waveform fine.
2. **Buttons** (`Button.qml` background): every press flips
   `buttonPressedBackground` on and off — two waveform updates per tap at
   Content quality. Wrap the background Rectangle in a `Fast`/`UFast` area.
3. **Clock/status texts** (`BoardScreen.qml` clock, "Your move" line,
   statusText): `Fast`.
4. Keep `Content` (default) for screen-level navigation repaints — those are
   the "crisp final state" moments.

Verify on device only; the PC emulator stubs this to `console.log`.

## B. E-ink: real redraw sources found in QML

- **B1. `TextField` cursor blink** (`SetupScreen`, `SeekScreen` ×4,
  `BoardScreen` chat). QtQuick's default blinking cursor = a waveform update
  every ~500ms the whole time a field has focus. Fix: shared TextField wrapper
  (same pattern as `Button.qml`) with a static, non-blinking
  `cursorDelegate: Rectangle { ... }` (no SequentialAnimation), themed to
  match. This also fixes the un-themed default Controls chrome those fields
  still have, and the hardcoded widths (340/220/560) that ignore Theme scaling.
- **B2. Promotion `Popup` modal dim** (`BoardScreen.qml:507`). `modal: true`
  draws a translucent overlay over the entire screen → full-screen damage on
  open *and* close, plus the Basic style's default fade `enter`/`exit`
  transitions animate opacity (multi-frame refresh). Set
  `enter: null; exit: null` and `Overlay.modal: Rectangle { color:
  "transparent" }` (or `dim: false`) — keep `modal: true` for input blocking.
- **B3. Highlight damage area**: tap-to-select fills the selected square plus
  every legal destination (up to ~28 squares, scattered rects). Cheap option:
  a Settings toggle "minimal highlights" that draws only the selected square
  (skip destination fill), halving damaged area per selection round-trip.
  Pairs with A1's Fast waveform. (Drag-to-move stays deferred per
  ui-strategy P4 — don't re-decide.)
- **B4. Disabled buttons look identical to enabled** (`GameReviewScreen` nav
  Buttons use `enabled:`, `Button.qml` has no disabled visual). On e-ink,
  a dead-looking tap with zero feedback reads as "app frozen". Add a
  disabled state (muted text/border) to `Button.qml`.
- **B5. `smooth: true` piece Images with no `sourceSize`**
  (`BoardSquare.qml:44`, promotion popup): PNGs are 192×192, board squares
  render larger than that (board ≈ height−320 → squares well over 100px, and
  the promotion tiles are 128 with 0.82 fill). Upscaling + bilinear filter =
  slightly soft edges, the worst case for e-ink. Re-rasterize cburnett SVGs at
  ≥256px (they're already in the repo as SVGs) and set
  `sourceSize.width/height` to the render size.

Already right (keep): no Timers, no animations, `StopAtBounds` everywhere,
frozen clock, saturated Gallery-3-aware palette, warm-gray dark mode.

## C. E-ink/CPU: cheap frame-latency wins (no refresh-count change)

- **C1. `pieceAt()` re-parses the FEN per square** — 64 full FEN string walks
  per position change (×2 in review's `lastMoveSquares()`, which is 128).
  Precompute once: `property var pieceMap: buildPieceMap(fen)` and index it.
- **C2. `filesRanks()` allocates fresh arrays per binding** — 64 squares + 16
  labels each call it (twice for squares). Cache as
  `property var fr: filesRanks()` like `selectedDestinations` already does.
- **C3. Stale comment**: `BoardScreen.qml` Column comment says grid formula is
  `height - 200`; code says `- 320`.

## D. Unfinished feature work (uncommitted diff vs the phased plan)

Phase 1 (game review) is complete end-to-end incl. QML + tests. Phases 2–4:
**backend halves done and tested, every QML half missing** — the features are
dead on arrival as-is:

- **D1. RatingDiff**: backend sends it (`backend_app.rs:357`); `main.qml`'s
  router has no branch for it → silently dropped. Add the branch + the
  `BoardScreen` append logic from the plan.
- **D2. Move confirmation**: `settings.rs`/protocol plumbed; no
  `SettingsScreen` toggle, no `BoardScreen` confirm gate.
- **D3. Low-time warning**: `initial_clock_ms` plumbed through BoardState;
  `BoardScreen` ignores it, no `isLowTime` coloring. (Plan called this phase
  "QML-only" — it's entirely absent.)
- **D4. Settings clobber (latent bug)**: `main.qml:56` sends `SaveSettings`
  with only `auto_queen_promotion`; `move_confirmation` serde-defaults to
  `false` → toggling auto-queen will silently reset move-confirmation once D2
  ships. Send and read both fields now.
- **D5. In-flight analysis/clock feature breaks the device build** — see E2.

## E. Backend (tested + clippy-clean, but)

- **E1. HIGH — NDJSON lines split across HTTP chunks are dropped**
  (`lichess/client.rs:461` `response_to_lines`): chunks are split
  independently with `.lines()`, no carry buffer. A `gameFull`/`gameState`
  line straddling a chunk boundary (inevitable in long games) becomes two
  unparseable fragments, silently dropped → missed moves/game-over. Fix:
  carry the trailing partial line across chunks (or `FramedRead`+`LinesCodec`).
- **E2. HIGH — `cargo build --features transport` doesn't compile** (what
  `build-rm.sh` ships): `backend_app.rs:202` `GameMoves` missing new
  `analysis`/`clock_ms`; `:741` missing `your_analysis`; test helpers `:795,804`.
  Also: since `backend_app.rs` is feature-gated, default `cargo test` never
  compiles it — CI/verify loop should run `cargo test --features transport`.
- **E3. HIGH — unencrypted SSH private key at repo root** (`remarkable`,
  `remarkable.pub`), not in `.gitignore` — one `git add .` from being
  committed. Gitignore or move out.
- **E4. Second seek leaks the first** (`backend_app.rs:240,569`): overwriting
  `pending_seek`'s JoinHandle detaches, doesn't cancel → old seek stays live
  on Lichess; `CancelSeek` only kills the newest. `.take().abort()` first.
- **E5. Logout leaks the account event stream** (`spawn_streams` handle never
  stored; `handle_log_out` aborts nothing): orphan task reconnects with the
  revoked token forever, spamming `Reconnecting`; each login adds another.
- **E6. Infinite reconnect to finished games** (`spawn_game_stream:461`): the
  `Full` arm never checks `status != "started"` → attaching to an
  already-finished game reconnects every 30s forever.
- **E7. Aborted games show "Game over: Draw (aborted)"**
  (`backend_app.rs:479` `winner.unwrap_or("draw")`); history code at `:731`
  already does this right — reuse it.
- **E8. Low**: silent `Err(_) => None` on `from_game_full` (`:467`, blank
  board no feedback); stale session blocks resume of next game after game-over
  (`:149`); `main.rs:13` bare double-unwrap panic; `chatMessages` unbounded in
  QML (cap it).

## F. Scripts

- **F1. `build-rm.sh:16` breaks if `CARGO_TARGET_DIR` is set** — which the
  phased plan itself tells developers to export. `unset CARGO_TARGET_DIR` at
  the top (or resolve via `cargo metadata`).
- **F2. `deploy.sh` is rm-then-scp**: failed scp leaves the device with no
  app; no check `dist/remarkable-lichess` exists. scp to temp dir + `mv`.
- **F3. Doc drift**: `build-rm.sh:5` references a `Cross.toml` that doesn't
  exist; qt6 apt install re-runs silently every build.

## Suggested order

1. E3 (30 seconds, security), E2/D5 (unbreaks device build), F1/F2.
2. E1 (correctness of live play), E4–E7.
3. D1–D4 (finish the already-planned QML halves — small, spec'd).
4. A (DisplayMethodArea wiring) + B1/B2 — the actual e-ink feel; needs
   on-device verification anyway, so batch them into one device pass.
5. B3–B5, C1–C2 polish.
