# Developer handoff

Last updated: 2026-07-27

This is the fastest path to understanding, running, and safely extending
`remarkable-lichess`.

## What the app is

A Lichess Board API client for reMarkable AppLoad. The frontend is Qt Quick/QML
compiled into `resources.rcc`; the Rust backend handles authentication, Lichess
HTTP/streaming APIs, chess rules, persistence, and the AppLoad message protocol.

The current UI supports:

- token setup, home ratings, ongoing games, seeks, direct/open/AI challenges;
- live games with tap or drag input, legal targets, premoves, promotion,
  move confirmation, clocks, player bars, chat, contract-gated draw/takeback,
  abort/resign, opponent-left claims, time gifts, typed action-completion
  feedback, reconnect and game-over states;
- game-history filters and finished-game review;
- clickable move notation, first/previous/next/last, board flip, annotations,
  a linear candidate-line Explore mode with Undo/Reset, and on-demand cached
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
| Visual system | `frontend/ui/Theme.qml`, `BoardStyle.qml`, `BoardPreview.qml` | App chrome, shared board palettes/piece choices, and the settings preview |
| Shared controls | `frontend/ui/AppButton.qml`, `AppDialog.qml`, `BoardToolButton.qml`, `ConfirmAction.qml`, `EinkRefreshArea.qml`, `MoveRequestGate.qml`, `MoveTokenButton.qml`, `PromotionDialog.qml`, `AppTextField.qml` | Consistent actions, confirmations, overlays, refresh policy, move submission, move tokens, promotion choices, and inputs |
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
   -input frontend/tests -import frontend/ui'
```

Always also run:

```bash
git diff --check
```

Minimum emulator smoke test:

1. Home → Game history → open a game → Back to Game History → Back to Home.
2. In review, tap move tokens and use previous/next plus first/last from Menu.
3. Request Cloud evaluation from Menu and verify the eval and best line.
4. Enter Explore, make one tap move and one drag move, Undo, Reset, and Exit.
5. Start or resume a game and verify orientation, legal targets, promotion,
   premove behavior, fixed-width clock alignment, top status, and that Back to
   Home appears only after GameOver.
6. Verify abort is shown only through the first ply; after both players move,
   verify draw/takeback availability and that resign replaces abort.
7. In a casual human clock game, verify Give opponent 15s; confirm it is absent
   for rated, AI, tournament, and untimed games.
8. Verify incoming draw/takeback accept and decline, outgoing takeback cancel,
   and opponent-left claim actions.
9. Open Actions, Moves, Chat (human games), move confirmation, and review Menu;
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
- Live play keeps a fixed three-control strip below the board: Actions, Moves,
  and Chat. Chat is disabled for computer games. Draw/takeback offers and
  disconnect claims change and highlight the Actions label.
- Turn, submission, check, premove, and connection status share one compact
  Fast-refresh line in the top player bar. Live games cannot navigate Home;
  GameOver enables and reveals the bottom navigation action.
- Live clocks refresh every 10 seconds above one minute, align one transition
  refresh with the one-minute boundary, and refresh every second thereafter.
  First-move deadlines use the same adaptive cadence.
- Page actions use the 144 px `AppButton`; the board strip uses the visually
  smaller 96 px `BoardToolButton`, still about a 9 mm touch target.
- Overlays use `AppDialog`, promotion uses `PromotionDialog`, and live/review
  notation uses `MoveTokenButton`. Extend these components instead of creating
  screen-local popup or button styles.
- Abort, draw offer, resignation, and Berserk use `ConfirmAction`; keep their
  confirmation and cancel behavior shared instead of duplicating armed-state
  button pairs.
- Accepting or claiming a draw and gifting clock time also use
  `ConfirmAction`. Critical confirmations use the shared dark full-fill state;
  do not add screen-local warning colors.
- Every server-backed live action returns the typed `GameActionCompleted`
  message. `BoardScreen.requestGameAction` owns pending state and duplicate-tap
  prevention; new action endpoints should use the same path.
- Every move request passes through `MoveRequestGate`. The move endpoint returns
  a typed `MoveSubmitted` acknowledgement, but the gate remains closed until the
  exact move appears in the authoritative game stream. This prevents duplicate
  submissions without adding an extra e-ink redraw between HTTP acceptance and
  the resulting `BoardState`.
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

The build creates `dist/remarkable-lichess`. Deployment stages the new app
before replacing the installed copy and retains the previous version under
`/home/root/xovi/exthome/appload-backups`. Never keep a rollback directory
inside the AppLoad app root: AppLoad scans every child directory and a duplicate
manifest ID can shadow the live installation. Recheck XOVI/AppLoad compatibility
with the tablet's current firmware before deployment.

## Highest-value remaining work

1. Persistent variation branches instead of only a linear scratch line.
2. On-demand opening explorer.
3. PGN export before platform-specific sharing.
4. A final real-device pass for ghosting, latency, physical touch size, and
   Paper Pro Move orientation.

Do not add a continuously updating engine or dense desktop analysis panel by
default; both are poor fits for e-ink.

## Supporting research

- `docs/chess-ui-research-audit-2026-07-27.md` — current comparison with Lichess
  and Chess.com plus remaining feature priorities.
- `docs/ui-strategy-2026-07-21.md` — whole-app UI strategy and implementation
  history.
- `docs/remarkable-appload-platform-notes.md` — AppLoad, XOVI, e-ink refresh,
  build, and deployment constraints.
- `docs/audit-2026-07-21-eink-and-repo.md` — earlier repository and e-ink audit.

Never commit `.lichess-token` or print its contents in logs.
