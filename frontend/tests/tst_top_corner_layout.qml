import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "TopCornerLayout"
    when: windowShown
    width: 1696
    height: 2384

    Theme {
        id: theme
    }

    BoardScreen {
        id: board
        width: 1696
        height: 2384
        backendSender: function() {}
    }

    function init() {
        board.statusText = ""
        board.gameOver = false
        board.firstMoveTimeMs = null
        board.initialClockMs = null
        board.lastClockSyncMs = 0
        board.turn = "white"
        board.yourColor = "white"
        board.whiteTimeMs = 0
        board.blackTimeMs = 0
        board.liveWhiteTimeMs = 0
        board.liveBlackTimeMs = 0
        board.gameId = ""
        board.fen = ""
        board.liveFen = ""
        board.previewFen = ""
        board.showGameActions = false
        board.showMoves = false
        board.pendingPromotion = null
        board.pendingMoveConfirmation = null
        board.legalMoves = []
        board.moveHistory = []
        board.positionHistory = []
        board.capturedByWhite = []
        board.capturedByBlack = []
        board.yourName = ""
        board.yourRating = null
        board.opponentName = ""
        board.opponentRating = null
    }

    function test_pageDoesNotReserveAFullExitBar() {
        compare(theme.pageTopMargin, theme.exitButtonMargin)
        verify(theme.pageTopMargin < theme.exitButtonMargin + theme.exitButtonSize)
    }

    function test_closedBoardDialogsStayUnloaded() {
        var actionsLoader = findChild(board, "gameActionsLoader")
        var historyLoader = findChild(board, "moveHistoryLoader")
        var promotionLoader = findChild(board, "promotionLoader")
        var confirmationLoader = findChild(board, "moveConfirmationLoader")
        verify(actionsLoader !== null)
        verify(historyLoader !== null)
        verify(promotionLoader !== null)
        verify(confirmationLoader !== null)
        compare(actionsLoader.item, null)
        compare(historyLoader.item, null)
        compare(promotionLoader.item, null)
        compare(confirmationLoader.item, null)
        board.showMoves = true
        verify(historyLoader.item !== null)
        board.showMoves = false
        compare(historyLoader.item, null)
    }

    function test_playerBarsAndToolbarShareTheExitSafeWidth() {
        var topPlayerBar = findChild(board, "topPlayerBar")
        var bottomPlayerBar = findChild(board, "bottomPlayerBar")
        var boardToolbar = findChild(board, "boardToolbar")
        verify(topPlayerBar !== null)
        verify(bottomPlayerBar !== null)
        verify(boardToolbar !== null)
        compare(topPlayerBar.width, bottomPlayerBar.width)
        compare(topPlayerBar.width,
                board.width - theme.pageSideMargin * 2 - theme.pageTopRightInset)
        compare(boardToolbar.width, topPlayerBar.width)
        compare(topPlayerBar.y, 0)
    }

    function test_opponentIdentityStaysBold() {
        var topPlayerBar = findChild(board, "topPlayerBar")
        var bottomPlayerBar = findChild(board, "bottomPlayerBar")
        var topName = findChild(topPlayerBar, "playerNameText")
        var bottomName = findChild(bottomPlayerBar, "playerNameText")
        board.yourColor = "white"
        board.turn = "white"
        compare(topPlayerBar.opponent, true)
        compare(bottomPlayerBar.opponent, false)
        compare(topName.font.bold, true)
        compare(bottomName.font.bold, true)
        board.turn = "black"
        compare(topName.font.bold, true)
        compare(bottomName.font.bold, false)
    }

    function test_liveStatusUsesTopPlayerBar() {
        board.statusText = ""
        board.gameOver = false
        board.yourColor = "white"
        board.turn = "white"
        compare(board.topStatusText(), "Your move")
        board.turn = "black"
        compare(board.topStatusText(), "Waiting for opponent")
        board.statusText = "Reconnecting..."
        compare(board.topStatusText(), "Reconnecting...")
    }

    function test_homeNavigationRequiresGameOver() {
        var backButton = findChild(board, "boardBackButton")
        verify(backButton !== null)
        board.gameOver = false
        compare(board.canNavigateHome, false)
        compare(backButton.enabled, false)
        board.gameOver = true
        compare(board.canNavigateHome, true)
        tryCompare(backButton, "enabled", true)
    }

    function test_clockRefreshCadence() {
        board.lastClockSyncMs = 0
        board.firstMoveTimeMs = null
        board.initialClockMs = 600000
        board.turn = "white"
        board.whiteTimeMs = 120000
        compare(board.clockRefreshIntervalMs(), 10000)
        board.whiteTimeMs = 65000
        compare(board.clockRefreshIntervalMs(), 10000)
        board.whiteTimeMs = 60000
        compare(board.clockRefreshIntervalMs(), 10000)
        board.initialClockMs = null
        board.firstMoveTimeMs = 30000
        compare(board.clockRefreshIntervalMs(), 10000)
    }

    function test_metadataOnlyUpdateDoesNotWakeBoardCollections() {
        var fen = "8/8/8/8/8/8/4P3/4K2k w - - 0 1"
        board.handleMessage({
            type: "BoardState",
            game_id: "g1",
            fen: fen,
            turn: "white",
            white_time_ms: 60000,
            black_time_ms: 60000,
            legal_moves: [{from: "e2", to: "e3", promotion: null}],
            position_history: [fen],
            move_history: [],
            captured_by_white: [],
            captured_by_black: []
        })
        var retainedLegalMoves = board.legalMoves
        var retainedPositionHistory = board.positionHistory
        board.handleMessage({
            type: "BoardState",
            game_id: "g1",
            fen: fen,
            turn: "white",
            white_time_ms: 59000,
            black_time_ms: 60000,
            legal_moves: [{from: "e2", to: "e4", promotion: null}],
            position_history: ["should not replace"],
            move_history: ["should not replace"],
            captured_by_white: ["bQ"],
            captured_by_black: [],
            draw_offered_by_opponent: true
        })
        verify(board.legalMoves === retainedLegalMoves)
        verify(board.positionHistory === retainedPositionHistory)
        compare(board.whiteTimeMs, 59000)
        compare(board.drawOfferedByOpponent, true)
    }

    function test_unacceptedMovePreviewRollsBackCleanly() {
        var liveFen = "8/8/8/8/8/8/4P3/4K2k w - - 0 1"
        var previewFen = "8/8/8/8/4P3/8/8/4K2k b - - 0 1"
        board.handleMessage({
            type: "BoardState",
            game_id: "g1",
            fen: liveFen,
            turn: "white",
            white_time_ms: 60000,
            black_time_ms: 60000,
            legal_moves: [{from: "e2", to: "e4", promotion: null}],
            position_history: [liveFen],
            move_history: [],
            captured_by_white: [],
            captured_by_black: []
        })
        board.handleMessage({
            type: "MovePreview",
            game_id: "g1",
            fen: previewFen,
            turn: "black",
            white_time_ms: 59000,
            black_time_ms: 60000,
            last_move: ["e2", "e4"],
            in_check: false
        })
        compare(board.fen, previewFen)
        compare(board.liveFen, liveFen)
        compare(board.turn, "black")
        compare(board.whiteTimeMs, 59000)
        board.handleMessage({type: "MoveRejected", reason: "network error"})
        compare(board.previewFen, "")
        compare(board.fen, liveFen)
        compare(board.turn, "white")
        compare(board.whiteTimeMs, 60000)
        compare(board.statusText, "Move rejected: network error")
    }

    function test_reconnectRollsBackUnconfirmedMovePreview() {
        var liveFen = "8/8/8/8/8/8/4P3/4K2k w - - 0 1"
        var previewFen = "8/8/8/8/4P3/8/8/4K2k b - - 0 1"
        board.handleMessage({
            type: "BoardState",
            game_id: "g1",
            fen: liveFen,
            turn: "white",
            white_time_ms: 60000,
            black_time_ms: 60000,
            legal_moves: [{from: "e2", to: "e4", promotion: null}],
            position_history: [liveFen],
            move_history: [],
            captured_by_white: [],
            captured_by_black: []
        })
        board.handleMessage({
            type: "MovePreview",
            game_id: "g1",
            fen: previewFen,
            turn: "black",
            white_time_ms: 59000,
            black_time_ms: 60000,
            last_move: ["e2", "e4"],
            in_check: false
        })
        board.handleMessage({type: "GameStreamReconnecting"})
        compare(board.previewFen, "")
        compare(board.fen, liveFen)
        compare(board.turn, "white")
        compare(board.whiteTimeMs, 60000)
        compare(board.statusText, "Reconnecting...")
    }

    function test_playerBarsUseBothAvailableRatings() {
        board.yourColor = "white"
        board.username = "fallback"
        board.yourName = "GM Alice"
        board.yourRating = 2210
        board.opponentName = "Stockfish level 3"
        board.opponentRating = null
        compare(board.nameFor("white"), "GM Alice")
        compare(board.ratingFor("white"), 2210)
        compare(board.nameFor("black"), "Stockfish level 3")
        compare(board.ratingFor("black"), null)
    }

    function test_gameOverReasonIsReadable() {
        board.yourColor = "white"
        board.handleMessage({
            type: "GameOver",
            result: "black",
            reason: "Time forfeit"
        })
        compare(board.statusText, "Game over: You lost (Time forfeit)")
        compare(board.gameReason, "Time forfeit")
    }
}
