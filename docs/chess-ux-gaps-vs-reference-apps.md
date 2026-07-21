# Chess UX gaps vs. the best/most established chess apps

**Update (same session):** gaps 1-4 below (orientation, last-move highlight, check
indicator, coordinate labels) are now implemented -- backend changes verified with
`cargo test` (27/27 passing, including new tests for `your_color` resolution and
`in_check` detection via a real Fool's Mate sequence); QML changes are unverified
beyond brace-balance/manual review, same limitation as everything else QML in this
project. Gap 5 (turn-gating) and gap 6 (piece art) are still open. The clock was
also changed as part of this pass: no more local 1Hz ticking Timer -- see the
comment in `BoardScreen.qml` -- it now only shows time as of the last authoritative
server update, a deliberate e-ink-redraw-count tradeoff, not an oversight.

Researched by comparing this project's current QML against two directly relevant reference points:
lichess.org's own official open-source clients (`lichess-org/lila` the web client, and
`lichess-org/flutter-chessground` — the official board-rendering package used in lichess's own
mobile app), and `chessmarkable` (LinusCDE/chessmarkable) — the one real, shipped chess app for this
same reMarkable hardware family, which is the most directly relevant precedent since it's already
solved "chess on this exact kind of e-ink screen," not just "chess on any screen."

Everything below is a comparison finding, not yet implemented unless noted. Verified by reading these
projects' actual source/docs, not guessing from general chess-app familiarity.

## Real gaps found

1. **Board never flips based on which color you're playing.** `BoardScreen.qml` always renders rank 8
   at the top / rank 1 at the bottom — i.e. always White's-perspective orientation, regardless of
   which color the local player is actually assigned in a given game. Lichess's own official
   `flutter-chessground` package has `orientation` as an explicit, first-class constructor parameter —
   confirming every serious client treats this as required, not optional polish. Root cause: our
   `GameFull` model (`backend/src/lichess/models.rs`) doesn't even parse the real Lichess `gameFull`
   payload's `white`/`black` player-id fields, so there's currently no way for the backend to know or
   communicate which color the token's account is playing in a given game. Needs both a model change
   and a QML orientation flip.

2. **Backend already computes and sends the last move; the frontend silently ignores it.** This one's
   worth flagging loudly: `protocol::BackendMessage::BoardState` already has a `last_move: Option<(String,
   String)>` field, and `GameSession` (`backend/src/game/session.rs`) already computes it correctly on
   every position update. But `BoardScreen.qml`'s `handleMessage` never reads `msg.last_move` at all —
   the data already flows end-to-end and is just thrown away. Every reference app highlights the last
   move (Lichess's own theme CSS uses a dedicated `--last-move` color variable, e.g. a translucent
   teal/yellow depending on theme). This is the cheapest fix in this whole list since no new data
   plumbing is needed, only QML.

3. **No check indicator.** Neither the backend nor the frontend surfaces "king is in check" at all —
   not in `protocol::BackendMessage::BoardState`, not rendered anywhere. Lichess's theme CSS has a
   dedicated `--checks` color for exactly this (translucent orange/red on the checked king's square).
   `shakmaty::Position` already exposes `is_check()`, so this is a small backend addition
   (`session.rs` already computes the position every update) plus a new QML highlight color.

4. **No board coordinates (a–h / 1–8) shown anywhere.** Every mainstream client (lichess, chess.com,
   chessmarkable) labels files/ranks around the board so a player can read and communicate moves.
   Current `BoardScreen.qml` has no coordinate labels at all — purely a QML addition, no backend
   change needed (the file/rank strings are already computed locally in `filesRanks()`).

5. **No turn-based input gating.** `onSquareTapped` in `BoardScreen.qml` allows tapping any piece and
   acting on whatever's in the cached `legalMoves` list, with no check for whether it's actually the
   local player's turn. Since `legalMoves` is always the *authoritative* legal-move list for whoever's
   turn it is per the current FEN (computed once per position update, not per-tap), a player could
   currently tap and attempt to move the opponent's pieces during the opponent's turn — Lichess's own
   server is still the final authority and would presumably reject an out-of-turn move server-side,
   so this isn't a correctness bug, but every reference client disables input and clearly indicates
   whose turn it is rather than relying on the server to catch a confusing tap.

6. **Piece rendering is a font-glyph gamble, not the standard approach — this gamble was lost on
   real hardware.** The user ran the app on the actual reMarkable and reported seeing "squares" where
   pieces should be: the classic symptom of a font missing a Unicode code point (`.notdef`/tofu glyph,
   which renders as a small hollow box). Confirmed via `fonttools`: the 12 chess code points
   (U+2654-265F) are present in desktop DejaVu Sans but there was no guarantee the device's actual
   on-device font stack includes them, and evidently it doesn't. **Fixed** (stopgap, not the ideal
   long-term fix): subset DejaVu Sans down to just those 12 glyphs (~7KB), renamed to `ChessGlyphs`
   per DejaVu's license (subsetting = modifying, and the Bitstream Vera license forbids keeping the
   "DejaVu"/"Bitstream"/"Vera" name on a modified font), bundled at `frontend/assets/ChessGlyphs.ttf`
   + `LICENSE-ChessGlyphs.txt`, registered in `application.qrc`, and loaded via a `FontLoader` in
   `BoardSquare.qml` using a path relative to that QML file (not a hardcoded `qrc:/...` path — AppLoad
   mounts each app's `resources.rcc` under a per-app namespace per `scripts/build-rm.sh`'s own comment,
   so an absolute `qrc:/assets/...` reference would silently fail to resolve). This guarantees glyph
   coverage regardless of what the device ships by default. **Still worth doing later:** the original
   `glyphFor()` renders pieces as Unicode chess characters (♔♕♖♗♘♙/♚♛♜♝♞♟) via plain QML `Text`
   elements. This depends entirely on whichever font Qt resolves on the actual device having full,
   correctly-shaped glyphs at those code points — never verified, since there's no Qt toolchain
   anywhere in this project's dev loop to check. Every mainstream client (lichess included) renders
   pieces as vector art instead, specifically to avoid this exact font-coverage gamble. Lichess's own
   default piece set, **cburnett** (originally from Wikipedia, GPLv2+, freely reusable with
   attribution — see `lichess-org/lila`'s `COPYING.md` and `public/piece/cburnett/`), is flat black/
   white line art that's already naturally suited to e-ink (no gradients, no anti-aliasing tricks to
   worry about) — much closer to what this project's own design doc's unresolved "icon/visual asset"
   open item was gesturing at than gambling on font glyph coverage. `chessmarkable`, for comparison,
   used a free Pixabay vector piece set for the same reason (real vector art, not a font). Whether
   QML's `Image` element can load the SVGs directly on this specific Qt build (needs the Qt SVG plugin)
   or whether they'd need pre-rasterizing to PNGs at a few fixed sizes is unverified and worth checking
   early, since it changes the implementation approach.

## Not a gap — an intentional, correct divergence worth confirming, not "fixing"

`chessmarkable` supports **two** move-input methods: tap-then-tap (shows highlights, like this
project), and press-and-drag-to-release (which chessmarkable's own README notes explicitly avoids
showing highlights/possible-moves, i.e. fewer partial e-ink redraws per move). This project only
implemented tap-then-tap. That's a reasonable choice, not a bug — but worth being aware that the one
other person who's actually shipped a chess app on this hardware family found drag-to-move valuable
specifically *because* it sidesteps extra e-ink redraws, which ties directly into the earlier
refresh-optimization findings in `docs/remarkable-appload-platform-notes.md`. Worth reconsidering if
on-device testing shows the highlight-then-second-tap flow refreshes too much.

## Sources
- [lichess-org/flutter-chessground](https://github.com/lichess-org/flutter-chessground) (official board package, `orientation` parameter)
- [lichess-org/lila](https://github.com/lichess-org/lila) — `public/piece/cburnett/`, `COPYING.md`
- Lichess forum: [Tutorial - How to modify Lichess's board colors](https://lichess.org/forum/lichess-feedback/tutorial---how-to-modify-lichesss-board-colors) (`--last-move`, `--checks` CSS variables)
- [LinusCDE/chessmarkable](https://github.com/LinusCDE/chessmarkable) — README (move-input methods, Pixabay piece credit)
- [Are the Lichess piece sets free to use in other software? — lichess.org forum](https://lichess.org/forum/general-chess-discussion/are-the-lichess-piece-sets-free-to-use-in-other-software)
