# UI strategy: whole-app gap audit vs. official Lichess, and roadmap

**Status update (2026-07-26):** P0, P1, P2, and P3 are implemented. Game
review now includes move navigation, clocks, analysis judgments/evaluation,
large tappable move tokens, current-move auto-scroll, and offline candidate
lines with legal tap/drag input, promotion, undo, and reset. The live board now
shows rating change, opt-in move confirmation, low-time styling, material
advantage, exact captured-piece icons, redundant non-color
selection/legal/last-move/check cues, dual tap-tap/drag-to-move input, and a
post-game review/new-game flow. The active clock now projects from each
authoritative server state once per second, with a persisted opt-out for
minimum e-ink refresh activity. Opt-in premoves include queued-state markers,
safe authoritative execution/cancellation, and underpromotion choice. P4 is
implemented without intermediate drag animation so it avoids selection
redraws; its device-level refresh benefit still needs physical-panel
measurement. The live move list is now made of tappable plies that can browse
the position history and return to the current position. P5 is implemented
through an explicit annotation mode: tap for a square ring, drag for an arrow,
repeat a mark to remove it, or clear all marks. The current Board API exposes
no rematch endpoint, so rematch is not treated as a missing button that can be
wired up independently of a new challenge flow.

Supersedes `docs/chess-ux-gaps-vs-reference-apps.md` in scope (that doc only ever
covered `BoardScreen.qml`; all 6 of its findings are now closed, see its own
correction note). This one covers every screen and is grounded in two things:
(1) reading this project's current QML/Rust, not assumption, and (2) the actual
Lichess Board API OAuth scope boundaries plus the official `lichess-org/mobile`
app, not "what lichess.org the website can do" in general — because this app
only ever authenticates with `board:play`, and a large fraction of lichess.org's
website features are structurally unreachable from that scope no matter how
much QML gets written. Getting that boundary right matters more here than in a
generic "add more features" audit: it tells us what's actually a gap versus
what would require rearchitecting this project into something it isn't trying
to be.

## 1. Where the app already stands (verified against current code, not the stale doc)

This is further along than the existing docs suggest. Confirmed in
`BoardScreen.qml` + `backend/src/{protocol.rs,backend_app.rs,game/session.rs}`:
board orientation flip, last-move highlight, check highlight, coordinates,
turn-gating, real cburnett piece art, promotion picker (with underpromotion,
not just auto-queen), draw/takeback offer-and-respond, resign (two-tap armed),
abort, claim victory/draw, move history in SAN, opponent
name/rating, dark mode, auto-queen setting. Outside the board:
seek (rated/casual, color choice), direct challenge by username, open
(link-shareable) challenges, challenge AI by level, incoming-challenge
accept/decline, multi-game Home (not just one resumable game), game history
with rated/speed/color filters, token-based login with scope-specific error
messaging, and log-out.

That is, in fact, close to the entire practical surface of the Board API. The
one screen genuinely mid-flight is **game review** (post-game move-by-move
navigation): designed in
`docs/superpowers/specs/2026-07-21-game-review-move-navigation-design.md`
(today), not yet implemented — no `GameReviewScreen.qml` exists, `RequestGameMoves`/
`GameMoves` aren't in `protocol.rs` yet. That's the natural P0 below.

## 2. Confirmed API scope boundary (why the rest of lichess.org isn't "just missing")

Per the official OpenAPI spec (`lichess-org/api`, `doc/specs/lichess-api.yaml`),
`board:play`'s Board tag covers game stream, move, chat, seek, challenge
lifecycle, abort/resign/draw/takeback/claim. This product deliberately omits
chat to keep live play focused and e-ink-friendly. The API explicitly
disallows engine assistance and restricts time controls (Blitz only via direct
challenge/AI/bulk pairing, not open seek). Everything else lives under
different tags requiring different scopes never requested by this app:

- **Puzzles** — needs `puzzle:read`/`puzzle:write`.
- **Tournaments (Arena/Swiss)** — joining requires `tournament:write`
  (`api-tournament-id-join.yaml`); the Board/Bot tag descriptions state
  pools/tournaments are off-limits to board clients outright.
- **Studies/Broadcasts** — `study:read`/`study:write`.
- **Analysis/cloud eval, Opening Explorer** — separate tags; Explorer is even a
  separate host (`explorer.lichess.org`).
- **TV** — separate public read-only tag, spectator-only, not a game you're in.
- **Insights/stats dashboard** — no corresponding endpoint in the spec at all;
  website-only, not exposed to any OAuth scope.

None of these are "we haven't built the QML yet." They're a different OAuth
grant and, for puzzles/tournaments/analysis, a fundamentally different product
(engine-assisted or matchmaking-pool play) than "one human plays one game on a
physical board," which is this app's whole premise. Building any of them would
mean re-scoping the token and rewriting real chunks of `backend_app.rs`, not
extending the current screens. Treat section 4 below as the actual non-goal
list, not an oversight list.

## 3. Real, actionable gaps — prioritized

### P0 — Finish game review (already scoped, not yet built)
Already fully designed; just needs building per the existing spec. This is the
highest-value item purely because Game History currently ends at "here's a row
saying you lost to bob (1600), rapid, Italian Game" with no way to see how —
every reference client (lichess web/mobile, chess.com, chessmarkable) lets you
step through a finished game's moves. Do this first; it's designed, reviewed
conceptually, and low-risk (pure replay via `shakmaty`, already a dependency).

### P1 — Show rating change after a rated game ends
Confirmed via the July 2025 Lichess API changelog (PR #493,
`lichess-org/api`): the Board/Bot game stream's `gameFinish` event now
includes a `ratingDiff` field, and cloning `lichess-org/mobile` confirms this
is already load-bearing in the official client, not a paper field nobody
reads: `game_socket_events.dart` parses `ratingDiff: ({int white, int
black})?` straight off the socket event, and `game.dart` formats it exactly as
`'${white.ratingDiff! > 0 ? '+' : ''}${white.ratingDiff!}'` (i.e. "+8"/"-6",
sign-prefixed only on gains) for the PGN tags it exports. This app doesn't
parse it at all — `GameState` in `backend/src/lichess/models.rs` has
`status`/`winner` but nothing rating-shaped, and `BackendMessage::GameOver`
(`protocol.rs:169`) only carries `{result, reason}`. `GameOver` is constructed
in `backend_app.rs:427` straight from the parsed `state`, so this is a small,
contained addition: add the field to `GameState`, thread an `Option<i32>`
(signed) through `GameOver` relative to `your_color` (same pattern
`draw_offered_by_opponent` etc. already use), display it with the same
sign-prefixed "+8"/"-6" formatting next to the win/loss text in
`BoardScreen.qml` — no reason to invent different formatting than the official
client already settled on. It's presently the one piece of standard post-game
feedback missing outright, and the API now makes it free to add — no new
endpoint, just parsing a field that's already flowing.

### P2 — Move confirmation: confirmed real (upgraded from earlier "unconfirmed")
Cloned `lichess-org/mobile` locally and checked the actual source rather than
relying on forum/issue mentions: this is a real, shipped preference, not
speculative. `lib/src/model/game/game_controller.dart` has a `moveToConfirm`
field on game state plus explicit `confirmMove()`/`cancelMove()` methods
("Called if the player confirms/cancels the move when confirm move preference
is enabled"), wired to Confirm/Cancel buttons in
`lib/src/view/game/game_body.dart` and `offline_correspondence_game_screen.dart`.
The l10n strings (`preferencesMoveConfirmation` = "Move confirmation",
`confirmMove` = "Confirm move") mirror lichess.org's own website preference of
the same name. So this is squarely "match an existing official feature," not
just a hardware-justified invention — though the hardware argument still
applies on top: a mis-tapped move here can only be undone if the opponent
voluntarily accepts a takeback (`TakebackAction`), and e-ink's partial-refresh
cost makes a wrong move plus its correction a more expensive mistake than on a
phone. This project already has the right pattern in-house — the two-tap "arm"
pattern used for `Resign`/`LogOut` (`resignArmed`/`logOutArmed`) generalizes
directly to a `moveToConfirm` + Confirm/Cancel row, same shape as lichess
mobile's own implementation. Suggest as an opt-in `SettingsScreen` toggle
(default off — lichess's own default is off too, confirmed by
`board_preferences.dart`'s style of only enabling the pieces of state that ship
`defaultValue: true`; move confirmation isn't among them).

### P2.5 — Haptic feedback: confirmed real, but hardware capability unverified
Also confirmed in the same codebase, not guessed: `board_preferences.dart` has
a `hapticFeedback` bool (default **on**), and
`lib/src/model/common/service/move_feedback.dart` calls
`HapticFeedback.lightImpact()` on a normal move and `.mediumImpact()` when the
move gives check — a deliberately distinct "something important happened"
buzz. This is a genuinely cheap, zero-extra-e-ink-redraw way to confirm a tap
registered. Gate this the same way as sound: don't ship it until it's confirmed
the reMarkable hardware this app targets actually has a haptic motor at all
(unlike a phone, that's not a safe default assumption — check
`docs/remarkable-appload-platform-notes.md` / the AppLoad host API before
committing to this).

### P3 — Low-time visual warning (no audio claim)
`lichess-org/mobile` issue #785 confirms the official app has a clock warning
at ~1/8 of total time remaining (min 10s, max 60s), implemented as *audio*.
The active clock now projects locally once per second from the latest
authoritative `BoardState`, so this warning can appear at the correct moment.
Users can disable live ticking in Settings to minimize e-ink refresh activity.
There is no confirmed speaker on this reMarkable hardware family in
`docs/remarkable-appload-platform-notes.md`, so audio remains out of scope.

### P4 — Implemented: drag-to-move alternative
`BoardScreen.qml` accepts both tap-tap and press-drag-release through the same
legality, promotion, auto-queen, and move-confirmation path. Dragging has no
piece-follow animation or intermediate highlight update; the board changes
only on release, preserving the e-ink refresh advantage that chessmarkable
identified. White and black orientations, ordinary moves, confirmation, and
the promotion picker are covered by emulator harness checks. Physical-device
testing is still needed to quantify the refresh improvement.

### P5 — Pen-drawn move annotation
Cloning `lichess-org/flutter-chessground` (the official board-rendering
package both lichess web and mobile build on) turned up
`lib/src/widgets/board_annotation.dart` plus a genuine premove system
(`board_settings.dart`'s `premovable`/`autoQueenPromotionOnPremove` etc.) —
lichess supports user-drawn arrows/circles on the board (right-click-drag on
web, long-press-drag on mobile) for annotating candidate moves, a real,
established feature, not an edge case. Premoves are now implemented as an
opt-in preference: the queued move is marked without animation, then checked
against the next authoritative legal-move list before it can be sent. The
Arrow/shape annotation is implemented as an explicit board
mode so it cannot collide with normal move gestures. A tap adds a square ring
and a drag adds an arrow; repeating the same gesture removes that mark. Marks
clear on position changes, and the rendering follows either board orientation.

## 4. Explicitly out of scope (and why that's a decision, not a gap)

Puzzles, tournament play, studies/broadcasts, engine analysis/cloud eval,
opening explorer, TV/streaming, insights dashboard — all confirmed
unreachable under this app's current `board:play` scope (section 2). Each
would need its own OAuth scope, its own backend integration, and in the case
of puzzles/tournaments/analysis, contradicts this project's own premise (an
engine-assisted or matchmaking-pool feature has no obvious meaning on "a
physical board for playing your own game"). If any of these get requested
later, that's a scope-widening decision worth its own design doc and explicit
user sign-off on requesting the extra OAuth permission — not something to
build opportunistically because a QML screen felt easy to add.

## 5. Process note

Keep whichever audit doc is current in sync as gaps close — this session found
the previous doc's own "gap 5/6 still open" note had gone stale after later
commits shipped both, which could easily mislead the next person who reads it
looking for open work. Recommend a one-line "status: closed/open, as of commit
X" per finding going forward instead of a single prose update note at the top,
so staleness is local to the finding it describes rather than requiring
re-reading the whole file to know what's still true.

## Sources

Cloned locally and read directly (not inferred from docs/issues alone):
`lichess-org/mobile` (official Flutter app), `lichess-org/flutter-chessground`
(official board package), `LinusCDE/chessmarkable` (per the prior audit doc).
Specific files/commits cited below.

- This repo: `frontend/ui/BoardScreen.qml`, `backend/src/protocol.rs`,
  `backend/src/backend_app.rs`, `backend/src/lichess/models.rs`,
  `docs/superpowers/specs/2026-07-21-game-review-move-navigation-design.md`.
- [lichess-org/api OpenAPI spec](https://github.com/lichess-org/api/blob/master/doc/specs/lichess-api.yaml) — Board tag scope, tournament join scope.
- [lichess-org/api PR #493](https://github.com/lichess-org/api/pull/493) / [July 2025 Lichess changelog](https://lichess.org/forum/lichess-feedback/lichess-changelog-july-2025) — `ratingDiff` added to `gameFinish` stream event.
- `lichess-org/mobile`, `lib/src/model/game/game_controller.dart` (`moveToConfirm`/`confirmMove()`/`cancelMove()`), `lib/src/model/settings/board_preferences.dart` (`hapticFeedback`, `premoves` toggles), `lib/src/model/common/service/move_feedback.dart` (haptic light/medium-impact split), `lib/src/model/game/game_socket_events.dart` + `game.dart` (`ratingDiff` parsing/formatting) — cloned and read directly at HEAD as of 2026-07-21.
- [lichess-org/mobile issue #785](https://github.com/lichess-org/mobile/issues/785) — clock warning sound threshold logic (~1/8 total time, min 10s/max 60s).
- `lichess-org/flutter-chessground`, `lib/src/widgets/board_annotation.dart` + `board_settings.dart` — arrow/shape annotation and premove support in the official board package (P5).
- [lichess-org/mobile issue #740](https://github.com/lichess-org/mobile/issues/740) — premove behavior differs from web (noted for awareness only — premove isn't actioned as a gap above; see P5).
