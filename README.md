# remarkable-lichess

Play Lichess on a reMarkable tablet.

A [Lichess Board API](https://lichess.org/api#tag/Board) client built for
[AppLoad](https://github.com/asivery/rm-appload) on reMarkable e-ink devices —
QML frontend, Rust backend. Sign in by scanning a QR code, then play real rated
or casual games, review finished ones, and explore candidate lines, all on a
screen designed for paper rather than pixels.

<p align="center">
  <img src="docs/images/live-play.png" width="270" alt="A live game against Stockfish, with player bars, clocks, and last-move highlighting">
  <img src="docs/images/review.png" width="270" alt="Reviewing a finished game with a tappable score sheet">
  <img src="docs/images/settings.png" width="270" alt="Settings with a live board preview">
</p>

> **Status:** functional, but not a packaged release — you build and deploy it
> yourself. See [Build and deploy](#build-and-deploy-to-a-tablet). A final
> real-device pass for ghosting, latency, and Paper Pro Move orientation is
> still outstanding. Screenshots below are from the AppLoad PC emulator at the
> device's real 954×1696 canvas.

---

## Contents

- [Screenshots](#screenshots)
- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Run locally](#run-locally)
- [Build and deploy to a tablet](#build-and-deploy-to-a-tablet)
- [Validate changes](#validate-changes)
- [Repository layout](#repository-layout)
- [Designed for e-ink](#designed-for-e-ink)
- [Documentation](#documentation)
- [Credits and licenses](#credits-and-licenses)

---

## Screenshots

### Signing in

Scan the QR code with your phone and approve on lichess.org — an OAuth PKCE flow
that never asks you to type a token on a tablet keyboard. The redirect comes
straight back to the device over your local network. If you have no camera
handy, the full URL is printed underneath, and a personal access token still
works as a fallback.

| Scan to sign in | Fallbacks |
| --- | --- |
| <img src="docs/images/sign-in.png" width="330" alt="Sign-in screen showing a QR code to scan"> | <img src="docs/images/sign-in-token.png" width="330" alt="Sign-in screen scrolled down, showing Start over and Enter a token instead"> |

### Home and starting a game

Your ratings and ongoing games on one screen. New games can be an auto-paired
open seek, a direct challenge by username, a shareable open challenge link, or
a game against Stockfish levels 1–8.

| Home | New game | Challenges and computer |
| --- | --- | --- |
| <img src="docs/images/home.png" width="250" alt="Home screen with ratings and main actions"> | <img src="docs/images/new-game.png" width="250" alt="New game screen with time control, rated/casual, and color"> | <img src="docs/images/new-game-challenges.png" width="250" alt="Challenge by username, open challenge link, and Play vs Computer"> |

### Live play

Both players' names, titles, ratings, provisional markers, and clocks sit above
and below the board. A single non-blocking profile lookup enriches the bars with
presence, streaming, patron, and flair labels; it never polls during play. Turn,
submission, check, premove, and connection status share one compact line that
refreshes on its own so the rest of the screen stays still. Below the board, a
fixed two-control strip: **Actions** and **Moves**.

| Game start | Your move | Game actions |
| --- | --- | --- |
| <img src="docs/images/live-board.png" width="250" alt="A freshly started game against Stockfish level 3"> | <img src="docs/images/live-play.png" width="250" alt="Mid-game with the opponent's last move highlighted and a piece selected"> | <img src="docs/images/live-actions.png" width="250" alt="Game actions overlay with flip board, annotate, and resign"> |

| Move list | Confirming a resignation | Game over |
| --- | --- | --- |
| <img src="docs/images/live-moves.png" width="250" alt="Moves overlay showing the score sheet during a live game"> | <img src="docs/images/resign-confirm.png" width="250" alt="Resign armed into a confirm/cancel pair"> | <img src="docs/images/game-over.png" width="250" alt="Game over dialog offering home, review, or final board"> |

Destructive actions arm into an explicit confirm/cancel pair rather than firing
on one tap. Abort only appears through the first ply; after both players move it
is replaced by resign, and draw and takeback become available.

### Review and analysis

Every finished game is replayable. The score sheet is directly tappable, the
board and move list stay in sync, and analysis that costs network traffic is
always something you ask for explicitly.

| Game history | Replay | Board options |
| --- | --- | --- |
| <img src="docs/images/game-history.png" width="250" alt="Game history with rated, speed, and color filters"> | <img src="docs/images/review.png" width="250" alt="Reviewing a game at move 12 with the score sheet in sync"> | <img src="docs/images/review-menu.png" width="250" alt="Board options overlay with first, last, flip, and cloud evaluation"> |

| Cloud evaluation | Explore |
| --- | --- |
| <img src="docs/images/cloud-eval.png" width="330" alt="Cached Lichess cloud evaluation with score, depth, nodes, and a SAN best line"> | <img src="docs/images/explore.png" width="330" alt="Explore mode showing a candidate move with undo and reset"> |

**Cloud evaluation** pulls Lichess's cached analysis for the current position —
score, depth, node count, and the best line in SAN. **Explore** lets you push
candidate moves onto the position by tap or drag, with Undo and Reset, without
touching the real game.

### Settings

Board palette and piece set changes are previewed live on a real board using the
same renderer as gameplay, so what you see in Settings is exactly what you get.

| Appearance | Display and gameplay | Dark mode | Green / Chessnut |
| --- | --- | --- | --- |
| <img src="docs/images/settings.png" width="200" alt="Settings with dark mode toggle and live board preview"> | <img src="docs/images/settings-gameplay.png" width="200" alt="Display toggles, gameplay options, and log out"> | <img src="docs/images/settings-dark.png" width="200" alt="Settings in dark mode"> | <img src="docs/images/settings-themes.png" width="200" alt="Green board with the Chessnut piece set in dark mode"> |

Four board palettes (brown, blue, green, mono), three piece sets (cburnett,
merida, chessnut), a dark-first high-contrast theme, and per-user toggles for
coordinates, captured pieces, last-move highlighting, minimal highlights,
auto-queen promotion, move confirmation, premoves, the live clock, and an extra
resign/abort guard.

---

## Features

**Play**
- Rated and casual games over the Lichess Board API
- Open seeks with auto-pairing, direct challenges, open challenge links
- Games against Stockfish, levels 1–8
- Tap or drag input, legal-target display, premoves, promotion picker
- Optional move confirmation, clocks with first-move deadlines
- Player titles, provisional ratings, and one-shot presence/profile metadata
- Draw and takeback offers, abort, resign, opponent-left claims, time gifts
- Berserk in eligible arena games
- Reconnect and game-over handling

**Review**
- Filterable game history (rated/casual, speed, color played)
- Replay with tappable notation, first/previous/next/last, board flip
- On-demand cached Lichess cloud evaluation with a SAN best line
- Explore mode for linear candidate lines, with Undo and Reset

**Built for the device**
- Dark-first high-contrast palette, e-ink-focused sizing, minimal animation
- Changed-square-only board clearing instead of full-board black flashes
- Fast-refresh regions for clocks and status, `Content` refresh for the
  settled position
- Drag hysteresis so pen jitter is not read as a drag
- Touch targets around 9 mm

---

## How it works

The frontend is Qt Quick/QML compiled into a single `resources.rcc`. The Rust
backend owns authentication, the Lichess HTTP and streaming APIs, chess rules,
persistence, and the AppLoad message protocol. They talk over AppLoad's local
socket using tagged JSON.

```
QML (frontend/ui)                     Rust (backend/src)
─────────────────                     ──────────────────
main.qml  ──FrontendMessage(JSON)──▶  backend_app.rs ──▶ lichess/client.rs ──▶ Lichess API
   ▲                                        │                                       │
   │                                        ├──▶ game/session.rs  ◀── game stream ───┘
   └────────BackendMessage(JSON)────────────┴──▶ game/rules.rs, game/replay.rs
```

1. `main.qml` sends a tagged JSON `FrontendMessage`.
2. `backend_app.rs` handles it, calling the Lichess client or the chess modules.
3. The backend replies with a tagged JSON `BackendMessage`.
4. `main.qml` updates global state, navigates if needed, or forwards the message
   to the active screen's `handleMessage`.

Every wire message is defined in [`backend/src/protocol.rs`](backend/src/protocol.rs).
Add or rename messages there first, then update both routing sides.

Notable properties:

- The board state shown is always the one the Lichess game stream reports. QML
  never infers whether abort, draw, takeback, Berserk, or a time gift is legal;
  those come from backend-derived flags.
- Every move goes through `MoveRequestGate`. The gate stays closed until the
  exact move appears in the authoritative stream, so a double tap cannot submit
  twice and no extra e-ink redraw happens between HTTP acceptance and the real
  `BoardState`.
- One-shot requests have a 20-second deadline. Event and game streams reconnect
  after 30 seconds without a line or keepalive, so a half-open TCP connection
  cannot silently freeze the board.

---

## Requirements

To run the emulator:

- Docker
- Clones of [`rm-appload`](https://github.com/asivery/rm-appload) and
  [`xovi`](https://github.com/asivery/xovi) beside this repository, or
  `APPLOAD_HOST` / `XOVI_HOST` pointing at them

To deploy to hardware:

- A reMarkable with XOVI and AppLoad installed, reachable over SSH
- A Rust toolchain with the `aarch64-unknown-linux-gnu` target, plus
  [`cross`](https://github.com/cross-rs/cross) — `build-rm.sh` cross-compiles in
  a Linux container, so Docker is needed here too

Check XOVI/AppLoad compatibility against your tablet's current firmware before
deploying.

---

## Run locally

macOS cannot host AppLoad backends — they need Linux `AF_UNIX SOCK_SEQPACKET` —
so local development runs in a Docker PC emulator reached over noVNC.

```bash
./scripts/connect-lichess.sh lip_your_token
```

That validates the token, writes the gitignored `.lichess-token`, and starts the
emulator. Create a token with the scopes `board:play`, `challenge:read`,
`challenge:write`, and `preference:read` — the script prints a prepared link if
you run it with no argument.

Later runs:

```bash
./scripts/run-local.sh
```

Then open <http://localhost:6080/vnc.html>. The container is named
`remarkable-lichess-local`.

You can also skip the token entirely and use the in-app QR sign-in.

For a quick frontend-only redeploy into a running emulator:

```bash
docker exec remarkable-lichess-local sh -lc \
  'cd /workspace/remarkable-lichess/frontend &&
   /usr/lib/qt6/libexec/rcc --binary -o /tmp/remarkable-lichess-resources.rcc application.qrc &&
   install -m 0644 /tmp/remarkable-lichess-resources.rcc /workspace/rm-appload/applications_root/remarkable-lichess/resources.rcc &&
   pkill -x appload'
```

AppLoad restarts on its own. Loose QML edits are not picked up — the RCC has to
be rebuilt.

---

## Build and deploy to a tablet

```bash
./scripts/build-rm.sh
TABLET_HOST=10.11.99.1 ./scripts/deploy.sh
```

`build-rm.sh` produces `dist/remarkable-lichess`. `deploy.sh` copies it into a
staging directory on the device and only swaps it into place once the transfer
has fully succeeded, keeping the previous version under
`/home/root/xovi/exthome/appload-backups`.

A new backend binary needs a full AppLoad relaunch, not just a file copy.

> Never keep a rollback directory inside the AppLoad app root. AppLoad scans
> every child directory, and a duplicate manifest ID will shadow the live
> installation.

---

## Validate changes

Backend — 158 tests, including `wiremock`-backed Lichess client coverage:

```bash
cd backend
cargo test
cargo clippy --all-targets -- -D warnings
```

`cargo test` on macOS skips the transport-gated streaming code, so borrow and
move errors in it only surface when you compile for the device. A plain
`cargo check --target aarch64-unknown-linux-gnu` won't do it on macOS — there is
no `aarch64-linux-gnu-gcc` to link against — so use `cross`, which runs the
build in a Linux container:

```bash
cross check --features transport --target aarch64-unknown-linux-gnu
```

QML lint and the 13 shared interaction test suites, using the emulator's Qt:

```bash
docker exec remarkable-lichess-local sh -lc \
  'cd /workspace/remarkable-lichess &&
   /usr/lib/qt6/bin/qmllint --import disable --type disable --property disable \
   --unqualified disable --unused-imports disable --deprecated disable \
   --signal disable --required disable --alias disable frontend/ui/*.qml'

docker exec remarkable-lichess-local sh -lc \
  'cd /workspace/remarkable-lichess &&
   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner \
   -input frontend/tests -import frontend/ui'
```

[`docs/DEVELOPER_HANDOFF.md`](docs/DEVELOPER_HANDOFF.md) carries a 14-step
emulator smoke test for changes that touch live play.

---

## Repository layout

```
backend/src/
  protocol.rs        Every frontend/backend JSON message
  backend_app.rs     Request and event router
  settings.rs        Token and user settings persistence
  game/
    session.rs       Lichess game stream and authoritative board state
    rules.rs         Legal moves and move generation
    replay.rs        PGN replay for review
  lichess/
    client.rs        HTTP endpoints and response parsing
    stream.rs        Held-open event and game streams
    oauth.rs         PKCE sign-in
    models.rs        API types

frontend/
  ui/
    main.qml               AppLoad endpoint, routing, navigation, shared state
    BoardScreen.qml        Live game interaction
    GameReviewScreen.qml   Replay, tappable notation, exploration
    Theme.qml              App chrome
    BoardStyle.qml         Board palettes and piece sets
    ChessDisplay.qml       API-value to display-string mappings
    EinkRefreshArea.qml    Refresh-policy wrapper
    MoveRequestGate.qml    Move submission gating
    ...                    Shared controls and dialogs
  tests/                   QML interaction tests
  assets/                  Piece sets and the chess glyph font

scripts/
  connect-lichess.sh   Save a token and start the emulator
  run-local.sh         Start the emulator
  build-rm.sh          Cross-compile and stage dist/
  deploy.sh            Stage-and-swap deploy over SSH

docker/local-pc/       The emulator image
docs/                  Design notes, audits, and the developer handoff
```

---

## Designed for e-ink

The constraints that shaped this app, and that changes should respect:

- **The board is the primary surface.** Frequent review actions live in one
  compact line directly beneath it.
- **Refresh is a budget, not a freebie.** Only frequently changing regions such
  as clocks use `Fast`; the settled position returns to `Content`. Piece changes
  clear only the affected squares.
- **Minimal highlights are on by default.** Spraying every legal destination can
  dirty ~28 squares on a single tap.
- **No cosmetic animation, and no always-on engine.** Network-heavy analysis is
  explicitly requested, never continuous.
- **Shared components over screen-local variants.** Overlays use `AppDialog`,
  confirmations use `ConfirmAction`, notation uses one `MoveListRow` in both live
  and review contexts.
- **Avoid Qt `Popup`.** AppLoad's host scaling can place it outside the scaled
  canvas; use an in-canvas high-`z` `Item` overlay instead.

---

## Documentation

| Document | What's in it |
| --- | --- |
| [`docs/DEVELOPER_HANDOFF.md`](docs/DEVELOPER_HANDOFF.md) | The fastest path to running, understanding, and extending the app |
| [`docs/remarkable-appload-platform-notes.md`](docs/remarkable-appload-platform-notes.md) | AppLoad, XOVI, e-ink refresh, build, and deploy constraints |

Known remaining work: persistent variation branches instead of a single linear
scratch line, an on-demand opening explorer, PGN export, and a final real-device
pass for ghosting, latency, and Paper Pro Move orientation.

---

## Credits and licenses

This project is an unofficial client and is not affiliated with Lichess or
reMarkable.

- **Lichess** — the [Board API](https://lichess.org/api#tag/Board) and cloud
  evaluation. Lichess is free and open source; consider
  [donating](https://lichess.org/patron).
- **[rm-appload](https://github.com/asivery/rm-appload)** and
  **[xovi](https://github.com/asivery/xovi)** by asivery — the platform this
  runs on.
- **Piece sets**, all as distributed by Lichess in `lichess-org/lila`:
  *cburnett* by Colin M.L. Burnett, *merida* by Armando Hernandez Marroquin, and
  *chessnut* by Alexis Luengas. Per-set license terms are in each directory
  under `frontend/assets/pieces/`.
- **ChessGlyphs.ttf** — a subset of [DejaVu Sans](https://dejavu-fonts.github.io/)
  containing only the chess piece glyphs, bundled so the app doesn't depend on
  the Unicode chess block being present in device firmware. See
  [`frontend/assets/LICENSE-ChessGlyphs.txt`](frontend/assets/LICENSE-ChessGlyphs.txt).
- **[shakmaty](https://github.com/niklasf/shakmaty)** — chess rules in Rust.

No license has been chosen for this repository's own code yet.

Never commit `.lichess-token`, and never print its contents in logs.
