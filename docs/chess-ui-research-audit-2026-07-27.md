# Chess UI research audit — 2026-07-27

## Decision

Keep the current board-first layout and interaction model. It now covers the
essential behavior of a serious chess client: tap or drag moves, legal targets,
premoves, promotion choice, last move, check, clocks, player bars, move history,
direct move selection, board flipping, review, annotations, and candidate-line
exploration.

The best reMarkable adaptation is not a smaller copy of a phone app. It should
keep the board stable, use large controls, avoid cosmetic animation, and make
expensive analysis or data panels explicitly user-triggered.

## Findings applied now

- Added drag hysteresis to live play and review exploration. A small pen wobble
  across a square boundary remains a tap; a deliberate drag remains a move.
  Lichess Chessground uses the same separation and starts a drag only after a
  minimum distance.
- Matched the review controls to the hierarchy used by current Lichess and
  Chess.com mobile analysis: one compact row directly below the board for
  Menu, Explore, previous, and next. First, last, and flip remain available in
  Board options instead of crowding the board edge.
- Marked the changing clock text as an AppLoad `Fast` display region. AppLoad's
  own example uses that method for frequently changing text.
- Verified that all actions use shared controls. Page actions have a 144 px
  minimum height, while the compact board strip and move tokens use 96 px touch
  targets. Dialogs, promotion choices, and live/review move tokens now share
  dedicated components instead of maintaining screen-local variants.
- Verified Home → History → Review, previous/next navigation, direct move-token
  selection, first/last, board flip, Explore, candidate drag, Undo, Exit, and
  return navigation in the live AppLoad emulator.
- Added an explicit cloud-evaluation action to review. Results are cached per
  position, show depth and a SAN best line, and never poll in the background.
- Made the dark, higher-ink palette the default while retaining the light-mode
  toggle.
- Replaced the full-board black clearing frame with a short black clear on only
  squares whose piece occupancy or move/check highlight changed. This covers
  ordinary moves, castling, captures, en passant, and retired highlights
  without refreshing all 64 squares.
- Aligned live action visibility with the official stream and endpoint
  contracts: abort through the first ply, resign after that, draw/takeback only
  after a full move and only for eligible human games, opponent-left claims
  only after an `opponentGone` event, and outgoing takeback cancellation.
- Added the documented 15-second opponent time gift for eligible casual human
  clock games. The backend enforces the endpoint's 5–60 second range.
- Made Resume immediately replay the cached board state when its game stream is
  already attached, and restore existing player-room chat through the Board
  chat GET endpoint.
- Kept cached clocks authoritative across Home → Resume by advancing only the
  side to move from the last stream snapshot. Returning to the board no longer
  restores stale time.
- Replaced the narrow live-action cluster with a fixed Actions/Moves/Chat strip
  and in-canvas, scrollable sheets. Incoming draw/takeback offers and opponent
  disconnects replace the Actions label and use the dark highlighted state;
  Chat is server-disabled for computer games.
- Parsed first-move expiration, AI level, player title, variant, speed, and
  correspondence cadence from `gameFull`/`gameState`. The board now names
  Stockfish levels, shows the time-control summary in the action sheet, and
  surfaces an approximate first-move deadline using the existing clock tick.
- Gave both player clocks the same fixed chip width, keeping names and clock
  edges aligned when the time changes from `10:00` to `9:59`.
- Explicitly accepts Standard and From Position live games. Other variant
  streams now produce a named unsupported-variant error instead of attempting
  to replay them with Standard chess rules.

## Live action contract

| Action | UI rule | API behavior |
| --- | --- | --- |
| Abort | Before both players have moved; hidden in tournaments | Board abort endpoint remains authoritative |
| Resign | Replaces Abort after the opening full move | Two-tap confirmation |
| Offer draw | After one full move, against a human, with no active offer | `draw/true`; incoming offers expose Accept/Decline |
| Takeback | Casual non-tournament human games after one full move | `takeback/true`; outgoing offers can be cancelled |
| Give time | Casual non-tournament human clock games | Round add-time endpoint, fixed at 15 seconds in the UI |
| Claim victory/draw | Only while the opponent is reported gone | Server validates whether the claim is mature/legal |
| Berserk | Not exposed | Arena-only and Board clients cannot join tournament pools |
| Rematch | Not exposed | No public rematch path exists in the OpenAPI contract |

The Lichess stream is still the source of truth. These rules remove impossible
or misleading controls; endpoint errors are still surfaced because eligibility
can change between the latest stream event and the tap.

## What the current UI already gets right

| Reference behavior | Current implementation |
| --- | --- |
| Tap and drag move input | Both supported |
| Minimum-distance drag recognition | Supported |
| Legal destinations, last move, check | Supported |
| Premoves and promotion choice | Supported |
| Player bars and clocks around the board | Supported |
| Clickable move history that follows the current move | Supported |
| Flip, first, previous, next, and last controls | Supported |
| Analysis annotations and candidate moves | Supported |
| On-demand cached cloud evaluation | Supported |
| Large, consistent touch targets | Supported |
| Reduced animation for e-ink | Supported |
| Contract-gated game actions | Supported |
| Fixed, urgency-labeled action sheet | Supported |
| Localized changed-square clearing | Supported |
| Accurate cached clock resume | Supported |

## Highest-value features still missing

1. **Persistent variation branches.** The current Explore mode is a linear
   scratch line. A compact variation bar should appear only when a position has
   multiple saved replies, following Lichess mobile's approach. Do not render a
   full desktop analysis tree beside the board.
2. **On-demand opening explorer.** Show a compact move table for the current
   review position. Keep it off by default so it does not compete with the
   board or generate unnecessary network and display updates.
3. **PGN export.** Review is complete enough to make copying or exporting the
   game useful. Sharing should come after local export works reliably.

## Behaviors not worth copying

- Piece movement and scrolling animations.
- A continuously updating engine and evaluation bar.
- Bullet-first controls or sub-three-minute time controls.
- Dense desktop side panels.
- Always-visible variation or opening data when the user is playing a live
  game.

## Primary sources

- [Lichess Chessground board gestures](https://github.com/lichess-org/flutter-chessground/blob/main/lib/src/widgets/board.dart)
- [Lichess Chessground settings](https://github.com/lichess-org/flutter-chessground/blob/main/lib/src/board_settings.dart)
- [Lichess mobile move list](https://github.com/lichess-org/mobile/blob/main/lib/src/widgets/move_list.dart)
- [Lichess mobile analysis screen](https://github.com/lichess-org/mobile/blob/main/lib/src/view/analysis/analysis_screen.dart)
- [Lichess mobile bottom bar](https://github.com/lichess-org/mobile/blob/main/lib/src/widgets/bottom_bar.dart)
- [Lichess mobile variation bar](https://github.com/lichess-org/mobile/blob/main/lib/src/widgets/variations_bar.dart)
- [Lichess PGN viewer goals](https://github.com/lichess-org/pgn-viewer)
- [Lichess cloud-eval API](https://github.com/lichess-org/api/blob/master/doc/specs/tags/analysis/api-cloud-eval.yaml)
- [Lichess Board API paths](https://github.com/lichess-org/api/blob/master/doc/specs/lichess-api.yaml)
- [Lichess add-time endpoint](https://github.com/lichess-org/api/blob/master/doc/specs/tags/challenges/api-round-gameId-add-time-seconds.yaml)
- [Lichess Board chat endpoint](https://github.com/lichess-org/api/blob/master/doc/specs/tags/board/api-board-game-gameId-chat.yaml)
- [Lichess game-state event](https://github.com/lichess-org/api/blob/master/doc/specs/schemas/GameStateEvent.yaml)
- [Lichess game-full event](https://github.com/lichess-org/api/blob/master/doc/specs/schemas/GameFullEvent.yaml)
- [Lichess game player](https://github.com/lichess-org/api/blob/master/doc/specs/schemas/GameEventPlayer.yaml)
- [Lichess variant keys](https://github.com/lichess-org/api/blob/master/doc/specs/schemas/VariantKey.yaml)
- [Lichess opponent-gone event](https://github.com/lichess-org/api/blob/master/doc/specs/schemas/OpponentGoneEvent.yaml)
- [Chess.com mobile analysis help](https://support.chess.com/en/articles/10473022-how-do-i-use-game-analysis-on-the-app)
- [AppLoad](https://github.com/asivery/rm-appload)
- [reMarkable Qt Quick documentation](https://developer.remarkable.com/documentation/qt_epaper)
- [reMarkable Paper Pro specifications](https://remarkable.com/products/remarkable-paper/pro/details/features)
