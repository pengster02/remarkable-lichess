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
- Verified that all buttons use the shared controls. Page actions have a 144 px
  minimum height, while the compact board strip uses 96 px touch targets. No
  screen falls back to Qt's short default button.
- Verified Home → History → Review, previous/next navigation, direct move-token
  selection, first/last, board flip, Explore, candidate drag, Undo, Exit, and
  return navigation in the live AppLoad emulator.

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
| Large, consistent touch targets | Supported |
| Reduced animation for e-ink | Supported |

## Highest-value features still missing

1. **On-demand cloud evaluation in review.** Use Lichess's cached cloud-eval
   endpoint only when the user asks. It may return up to five principal
   variations and can return 404 when a position is not cached. This is a better
   fit than running Stockfish continuously on the tablet.
2. **Persistent variation branches.** The current Explore mode is a linear
   scratch line. A compact variation bar should appear only when a position has
   multiple saved replies, following Lichess mobile's approach. Do not render a
   full desktop analysis tree beside the board.
3. **On-demand opening explorer.** Show a compact move table for the current
   review position. Keep it off by default so it does not compete with the
   board or generate unnecessary network and display updates.
4. **PGN export.** Review is complete enough to make copying or exporting the
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
- [Chess.com mobile analysis help](https://support.chess.com/en/articles/10473022-how-do-i-use-game-analysis-on-the-app)
- [AppLoad](https://github.com/asivery/rm-appload)
- [reMarkable Qt Quick documentation](https://developer.remarkable.com/documentation/qt_epaper)
- [reMarkable Paper Pro specifications](https://remarkable.com/products/remarkable-paper/pro/details/features)
