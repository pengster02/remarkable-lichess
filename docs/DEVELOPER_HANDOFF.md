# Developer handoff

Last updated: 2026-08-21

This is the fastest path to understanding, running, and safely extending
`remarkable-lichess`.

## What the app is

A Lichess Board API client for reMarkable AppLoad. The frontend is Qt Quick/QML
compiled into `resources.rcc`; the Rust backend handles authentication, Lichess
HTTP/streaming APIs, chess rules, persistence, and the AppLoad message protocol.

The current UI supports:

- token setup, home ratings, ongoing games, seeks, direct/open/AI challenges;
- live games with tap or drag input, legal targets, premoves, promotion,
  move confirmation, clocks, both players' names/titles/ratings, provisional
  markers, one-shot presence/profile metadata,
  contract-gated draw/takeback,
  abort/resign, opponent-left claims, time gifts, typed action-completion
  feedback, reconnect and game-over states;
- game-history filters and finished-game review;
- clickable move notation, first/previous/next/last, board flip, annotations,
  locally saved branches in Explore, and on-demand cached
  Lichess cloud evaluation with a SAN best line;
- e-ink-focused sizing, a dark-first high-contrast palette, minimal animation,
  four board palettes, three common piece sets, a live settings preview, drag
  hysteresis, fast clock refresh regions, and changed-square-only board clearing.

## Read these files first

| Area | Entry point | Purpose |
| --- | --- | --- |
| Frontend shell | `frontend/ui/main.qml` | AppLoad endpoint, message routing, navigation, shared state |
| Live board | `frontend/ui/BoardScreen.qml` | Game interaction and live-game actions |
| Review | `frontend/ui/GameReviewScreen.qml` | Replay navigation, clickable moves, candidate exploration |
| Review variations | `frontend/ui/VariationTree.js`, `backend/src/variations.rs` | Branch navigation and per-account, per-game persistence |
| Visual system | `frontend/ui/Theme.qml`, `BoardStyle.qml`, `BoardPreview.qml`, `ChessDisplay.qml` | App chrome, board appearance, settings preview, and API-to-display mappings |
| Shared controls | `frontend/ui/AppButton.qml`, `AppDialog.qml`, `BoardToolButton.qml`, `ConfirmAction.qml`, `EinkRefreshArea.qml`, `MoveRequestGate.qml`, `MoveListRow.qml`, `MoveListCell.qml`, `PromotionDialog.qml`, `AppTextField.qml` | Consistent actions, confirmations, overlays, refresh policy, move submission, score-sheet rows, promotion choices, and inputs |
| Wire contract | `backend/src/protocol.rs` | Every frontend/backend JSON message |
| Backend router | `backend/src/backend_app.rs` | Dispatches frontend requests and backend events |
| Live chess state | `backend/src/game/session.rs` | Lichess game stream and authoritative board state |
| Chess calculations | `backend/src/game/rules.rs`, `game/replay.rs` | Legal moves, analysis moves, and PGN replay |
| Lichess client | `backend/src/lichess/client.rs` | HTTP endpoints and response parsing |
| Persistence | `backend/src/settings.rs` | Token and user settings |

Runtime flow:

1. `main.qml` sends a tagged JSON `FrontendMessage`.
2. `backend_app.rs` handles it and uses the Lichess client or chess modules.
3. The backend returns a tagged JSON `BackendMessage`.
4. `main.qml` updates global state, navigates when required, or forwards the
   message to the loaded screen's `handleMessage`.

Add or rename messages in `protocol.rs` first, then update both routing sides.

## Run locally

The AppLoad backend requires Linux `AF_UNIX SOCK_SEQPACKET`, so macOS development
uses the Docker PC emulator.

Prerequisites:

- Docker;
- `rm-appload` and `xovi` clones beside this repository, or `APPLOAD_HOST` and
  `XOVI_HOST` pointing to them;
- a Lichess personal access token with the scopes printed by
  `scripts/connect-lichess.sh`.

```bash
./scripts/connect-lichess.sh lip_your_token
```

That validates the token, writes the gitignored `.lichess-token`, and runs the
emulator. Later runs can use:

```bash
./scripts/run-local.sh
```

Open `http://localhost:6080/vnc.html`. The default container name is
`remarkable-lichess-local`.

For a quick frontend-only redeploy into an already running emulator:

```bash
docker exec remarkable-lichess-local sh -lc \
  'cd /workspace/remarkable-lichess/frontend &&
   /usr/lib/qt6/libexec/rcc --binary -o /tmp/remarkable-lichess-resources.rcc application.qrc &&
   install -m 0644 /tmp/remarkable-lichess-resources.rcc /workspace/rm-appload/applications_root/remarkable-lichess/resources.rcc &&
   pkill -x appload'
```

AppLoad restarts automatically. Loose QML edits are not loaded; rebuild the RCC.

## Validate changes

Backend:

```bash
cd backend
cargo test
cargo clippy --all-targets -- -D warnings
```

If the host toolchain has no Clippy component, run the same Clippy command
inside `remarkable-lichess-local`.

QML, using the running emulator's Qt installation:

```bash
docker exec remarkable-lichess-local sh -lc \
  'cd /workspace/remarkable-lichess &&
   /usr/lib/qt6/bin/qmllint --import disable --type disable --property disable \
   --unqualified disable --unused-imports disable --deprecated disable \
   --signal disable --required disable --alias disable frontend/ui/*.qml'
```

Shared QML interaction tests:

```bash
docker exec remarkable-lichess-local sh -lc \
  'cd /workspace/remarkable-lichess &&
   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
   -input frontend/tests -import frontend/ui -import frontend/tests/imports'
```

Always also run:

```bash
git diff --check
```

Minimum emulator smoke test:

1. Home → Game history → open a game → Back to Game History → Back to Home.
2. In review, tap moves in the score sheet and use previous/next plus first/last from Menu.
3. Request Cloud evaluation from Menu and verify the eval and best line.
4. Enter Explore and make a tap move and a drag move. Use Previous to back up,
   try another move, then select both lines. Reopen the review and verify the
   saved lines are still available from their archived position.
5. Start or resume a game and verify orientation, legal targets, promotion,
   premove behavior, fixed-width clock alignment, top status, and that Back to
   Home appears only after GameOver.
6. Verify abort is shown only through the first ply; after both players move,
   verify draw/takeback availability and that resign replaces abort.
7. In a casual human clock game, verify Give opponent 15s; confirm it is absent
   for rated, AI, tournament, and untimed games.
8. Verify incoming draw/takeback accept and decline, outgoing takeback cancel,
   and opponent-left claim actions.
9. Open Actions, Moves, move confirmation, and review Menu;
   verify each shared in-canvas dialog fits and scrolls.
10. In an eligible arena game, verify Berserk requires confirmation and
    disappears after success or the local player's first move.
11. Confirm a server-backed action; verify Actions briefly reads `Working...`,
    cannot be tapped twice, and returns to its authoritative state.
12. In a casual computer game, submit a move and immediately tap a second move.
    Verify `Submitting e2–e4` appears, only the first request reaches Lichess,
    and input unlocks when that exact move arrives in `BoardState`.
13. Check both light and dark modes.
14. In Settings, select every board palette and piece set; verify the mini board,
    live board, review board, captured pieces, and promotion picker stay in sync.

## UI rules that matter

- The board is the primary surface. Frequent review actions stay in one compact
  line directly below it: Menu, Explore, previous, next.
- Board palette and piece-set IDs are centralized in `BoardStyle.qml` and
  validated again in `backend/src/settings.rs`. The preview and gameplay boards
  use the same `BoardSquare` renderer; do not create a settings-only imitation.
- Result, termination, speed, variant, clock, annotation, and move-row display
  mappings live in `ChessDisplay.qml`. Live and review history both render the
  same `MoveListRow`; do not reintroduce screen-specific move tokens.
  Game History cards keep result and ratings in view, elide long opponent
  names, and omit the analysis line when the game has no analysis.
- `EinkPagedFlickable` uses the same page starts for navigation and numbering.
  It keeps supplied section starts, adds pages across gaps, and reaches the
  final content. Review can still reveal a particular row between starts.
- Live play keeps a fixed two-control strip below the board: Actions and Moves.
  Draw/takeback offers and disconnect claims change and highlight the Actions
  label.
- Turn, submission, check, premove, and connection status share one compact
  Fast-refresh line in the top player bar. Live games cannot navigate Home;
  GameOver enables and reveals the bottom navigation action.
- Player title/provisional data comes from the existing `gameFull` snapshot.
  Presence, streaming, patron, and flair use one asynchronous `/api/users/status`
  request after that snapshot; never block or poll the authoritative game stream.
  `opponentGone` remains the live source for disconnect and claim state.
- Game-over result logic keeps Lichess's raw status internally, but the backend
  sends a human-readable termination label such as `Time forfeit` for display.
- Live clocks and first-move deadlines refresh every 10 seconds above 60 seconds,
  every 5 seconds above 15 seconds through 60 seconds, and every second at 15
  seconds or less.
  A refresh is aligned with each transition into a faster cadence.
- Page actions use the 144 px `AppButton`; the board strip uses the visually
  smaller 96 px `BoardToolButton`, still about a 9 mm touch target.
- Overlays use `AppDialog`, promotion uses `PromotionDialog`, and live/review
  notation uses `MoveTokenButton`. Extend these components instead of creating
  screen-local popup or button styles.
  Promotion Cancel discards the draft in live play and Explore. Choosing a
  promotion for a premove replaces the previous queue only after piece selection.
- Abort, draw offer, resignation, and Berserk use `ConfirmAction`; keep their
  confirmation and cancel behavior shared instead of duplicating armed-state
  button pairs.
  Keep an armed action through clock-only snapshots while it remains
  eligible. A changed board or a hidden control requires a new confirmation.
- Accepting or claiming a draw and gifting clock time also use
  `ConfirmAction`. Critical confirmations use the shared dark full-fill state;
  do not add screen-local warning colors.
- `BoardScreen.requestGameAction` assigns a request ID. The backend runs one
  action per board at a time and returns a matching `GameActionCompleted` or
  `GameActionFailed` while the board remains active. A resumed snapshot carries
  the pending action, and the app does not automatically retry the POST.
  Scoped draw and takeback commands identify the selected intent and position.
  The backend checks the offer state at admission and dispatch. While the game
  stream reconnects, wait for a fresh snapshot before showing these actions.
  Position-scoped feedback stays visible through same-position clock and offer
  updates. A new move or action, board advance, stream failure, or outcome clears it.
- Every move request passes through `MoveRequestGate`. The gate releases on a
  scoped rejection or a `BoardState` that settles the request, from either HTTP
  acceptance or an authoritative game stream update.
  `MakeMove.expected_position_id` echoes the displayed live board's ID. The
  backend checks it under the session lock before emitting a preview or starting
  the POST. Clock and offer updates and unchanged reconnects preserve this ID.
  A move, takeback, rewritten line, or new attachment gets a new ID.
  While a move preview is visible, keep its clocks and receipt time together.
  Same-position frames update the live snapshot used for rollback, including its
  receipt time and first-move deadline.
  A new position or rewritten line cancels unsent move and promotion prompts.
  A queued premove can execute after the opponent adds one ply to the same line,
  including through a full reconnect snapshot. Takebacks cancel the queue.
- One-shot Lichess requests have a 20-second total deadline so move and action
  gates cannot remain pending forever after a dropped response. Held-open event,
  game, seek, and challenge streams use the separate unbounded stream path.
  Event and game consumers reconnect after 30 seconds without a line or
  keepalive so a half-open TCP connection cannot freeze authoritative updates.
- Move notation is directly tappable and automatically reveals the current move.
- Clock chips use a fixed shared width so both player bars remain aligned when
  a clock changes from two-digit to one-digit minutes.
- Use tap and drag. `Theme.boardDragThreshold` prevents pen jitter from becoming
  an accidental drag.
- Action visibility comes from backend-derived `BoardState` flags. Do not infer
  abort, Berserk, draw, takeback, or time-gift eligibility independently in QML.
- Cached `GameSession::board_state` advances the active clock from the last
  stream snapshot. Keep that correction when changing Resume behavior; stream
  clocks update on game events, not once per second.
- Live rules currently support the Standard and From Position variant keys.
  Adding another variant requires matching `shakmaty` rules and castling/UCI
  handling before loosening the explicit guard.
- Keep cosmetic animation out. Explicitly trigger network-heavy analysis panels.
- Use `DisplayMethodArea.Fast` only for frequently changing regions such as
  clocks; the PC emulator does not reproduce real e-ink waveform behavior.
- Use `EinkRefreshArea` instead of importing AppLoad's refresh component in
  individual controls. Board interaction and clearing states use `Fast`, while
  the settled colored position returns to `Content`. Shared buttons use `Fast`
  only while pressed and `UI` at rest.
- Import AppLoad's `DisplayMethodArea` through its embedded
  `qrc:/qt/qml/net/asivery/ApploadUtils` directory. The URI-style module import
  can pass lint yet fail when the PC emulator has not registered that import
  path.
- Piece changes briefly clear only the affected squares. Do not restore the
  former full-board black flash without real-device evidence that localized
  clearing is insufficient.
- Avoid Qt `Popup` for app overlays. AppLoad's host scaling can place it outside
  the scaled canvas. Use an in-canvas, high-`z` `Item` overlay instead.
- Keep navigation centralized through `main.qml`. Background game-stream events
  must not force a user who returned Home back onto the board.

## Build and deploy to a tablet

```bash
./scripts/build-rm.sh
TABLET_HOST=10.11.99.1 ./scripts/deploy.sh
```

The build creates `dist/remarkable-lichess`. Deployment uses a unique staging
directory outside AppLoad's scan root and serializes installation with a lock.
The previous version is retained under `/home/root/xovi/exthome/appload-backups`.
If the connection drops during installation, inspect the staging path printed by
the script before retrying. Recheck XOVI/AppLoad compatibility with the tablet's
current firmware before deployment.

## Highest-value remaining work

1. On-demand opening explorer.
2. PGN export before platform-specific sharing.
3. A final real-device pass for ghosting, latency, physical touch size, and
   Paper Pro Move orientation.

Do not add a continuously updating engine or dense desktop analysis panel by
default; both are poor fits for e-ink.

## Supporting research

- `docs/remarkable-appload-platform-notes.md` — AppLoad, XOVI, e-ink refresh,
  build, and deployment constraints.

Never commit `.lichess-token` or print its contents in logs.
