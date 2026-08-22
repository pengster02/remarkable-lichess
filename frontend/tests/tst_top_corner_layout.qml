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
        board.showGameOverDialog = false
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
        board.yourId = ""
        board.yourTitle = ""
        board.yourProvisional = false
        board.opponentName = ""
        board.opponentRating = null
        board.opponentId = ""
        board.opponentTitle = ""
        board.opponentProvisional = false
        board.gameDescription = ""
        board.resetPlayerStatuses()
    }

    // Screens are anchored under the persistent top bar already (see main.qml),
    // so this margin is only the gap beneath it -- it must never grow into a
    // second bar's worth of reserved space.
    function test_pageDoesNotReserveTheTopBarTwice() {
        verify(theme.pageTopMargin > 0)
        verify(theme.pageTopMargin < theme.topBarHeight)
    }

    function test_closedBoardDialogsStayUnloaded() {
        var actionsLoader = findChild(board, "gameActionsLoader")
        var historyLoader = findChild(board, "moveHistoryLoader")
        var promotionLoader = findChild(board, "promotionLoader")
        var confirmationLoader = findChild(board, "moveConfirmationLoader")
        var gameOverLoader = findChild(board, "gameOverLoader")
        verify(actionsLoader !== null)
        verify(historyLoader !== null)
        verify(promotionLoader !== null)
        verify(confirmationLoader !== null)
        verify(gameOverLoader !== null)
        compare(actionsLoader.item, null)
        compare(historyLoader.item, null)
        compare(promotionLoader.item, null)
        compare(confirmationLoader.item, null)
        compare(gameOverLoader.item, null)
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
        compare(topPlayerBar.width, board.width - theme.pageSideMargin * 2)
        compare(boardToolbar.width, topPlayerBar.width)
        compare(topPlayerBar.y, 0)
    }

    function test_timeControlDescriptionIsVisibleBesideTheBoard() {
        var description = findChild(board, "gameDescriptionText")
        verify(description !== null)
        compare(board.hasGameDescription, false)

        board.gameDescription = "Casual Rapid • 10 min + 0 sec/move"
        compare(board.hasGameDescription, true)
        compare(description.text, "Casual Rapid • 10 min + 0 sec/move")
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
        compare(bottomName.font.bold, false)
        board.turn = "black"
        compare(topName.font.bold, true)
        compare(bottomName.font.bold, false)
    }

    function test_structured_title_provisional_and_optional_status_render_without_layout_change() {
        var fen = "8/8/8/8/8/8/4P3/4K2k w - - 0 1"
        board.handleMessage({
            type: "BoardState", game_id: "identity-game", fen: fen, turn: "white",
            white_time_ms: 60000, black_time_ms: 60000, your_color: "white",
            legal_moves: [], position_history: [fen], move_history: [],
            captured_by_white: [], captured_by_black: [],
            your_player: {id: "alice", name: "Alice", rating: 1800, provisional: false},
            opponent_player: {
                id: "bob", name: "Bob", rating: 2501, title: "GM", provisional: true
            }
        })
        var retainedFen = board.fen
        var retainedLegalMoves = board.legalMoves
        var retainedPositionHistory = board.positionHistory
        board.handleMessage({
            type: "PlayerStatuses", game_id: "identity-game", players: [{
                id: "bob", title: "GM", online: true, playing: true,
                streaming: true, patron: true, flair: "symbols.white-heart"
            }]
        })
        compare(board.fen, retainedFen)
        verify(board.legalMoves === retainedLegalMoves)
        verify(board.positionHistory === retainedPositionHistory)

        var topPlayerBar = findChild(board, "topPlayerBar")
        var topTitle = findChild(topPlayerBar, "playerTitleText")
        var topName = findChild(topPlayerBar, "playerNameText")
        compare(topPlayerBar.height, theme.playerBarHeight)
        compare(topTitle.text, "GM")
        verify(topName.text.indexOf("Bob") !== -1)
        verify(topName.text.indexOf("(2501?)") !== -1)
        verify(topName.text.indexOf("Playing") !== -1)
        verify(topName.text.indexOf("Live") !== -1)
        verify(topName.text.indexOf("Patron") !== -1)
        verify(topName.text.indexOf("White heart") !== -1)

        board.handleMessage({type: "OpponentGone", gone: true, claim_win_in_seconds: 8})
        compare(topPlayerBar.presenceText, "Disconnected")
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
        compare(board.clockRefreshIntervalMs(), 5000)
        board.whiteTimeMs = 15000
        compare(board.clockRefreshIntervalMs(), 1000)
        board.whiteTimeMs = 120000
        board.initialClockMs = null
        board.firstMoveTimeMs = 30000
        compare(board.clockRefreshIntervalMs(), 5000)
        board.firstMoveTimeMs = 10000
        compare(board.clockRefreshIntervalMs(), 1000)
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

    function test_incrementalMovesAppendToHistoryAndFullSyncReplaces() {
        var fenA = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        var fenB = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
        var fenC = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"
        // Full sync establishes the baseline line.
        board.handleMessage({
            type: "BoardState", game_id: "g1", fen: fenA, turn: "white",
            white_time_ms: 60000, black_time_ms: 60000,
            legal_moves: [{from: "e2", to: "e4", promotion: null}],
            position_history: [fenA], move_history: [],
            captured_by_white: [], captured_by_black: []
        })
        // One-move advance: no arrays, just the appended SAN -- frontend grows its copy.
        board.handleMessage({
            type: "BoardState", game_id: "g1", fen: fenB, turn: "black",
            white_time_ms: 59000, black_time_ms: 60000, last_move: ["e2", "e4"],
            legal_moves: [{from: "e7", to: "e5", promotion: null}],
            appended_move: "e4", captured_by_white: [], captured_by_black: []
        })
        compare(board.positionHistory.length, 2)
        compare(board.positionHistory[1], fenB)
        compare(board.moveHistory.length, 1)
        compare(board.moveHistory[0], "e4")
        board.handleMessage({
            type: "BoardState", game_id: "g1", fen: fenC, turn: "white",
            white_time_ms: 59000, black_time_ms: 59000, last_move: ["e7", "e5"],
            legal_moves: [], appended_move: "e5",
            captured_by_white: [], captured_by_black: []
        })
        compare(board.positionHistory.length, 3)
        compare(board.moveHistory.length, 2)
        compare(board.moveHistory[1], "e5")
        // A later full sync (e.g. takeback/resume) replaces the whole line again.
        board.handleMessage({
            type: "BoardState", game_id: "g1", fen: fenA, turn: "white",
            white_time_ms: 60000, black_time_ms: 60000,
            legal_moves: [{from: "e2", to: "e4", promotion: null}],
            position_history: [fenA], move_history: [],
            captured_by_white: [], captured_by_black: []
        })
        compare(board.positionHistory.length, 1)
        compare(board.moveHistory.length, 0)
    }

    function test_pieceDelegatesReceiveCodesAndImageSources() {
        var before = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        var after = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
        board.fen = before
        wait(0)
        var e2Square = findChild(board, "boardSquare-e2")
        var e4Square = findChild(board, "boardSquare-e4")
        verify(e2Square !== null)
        verify(e4Square !== null)
        compare(e2Square.pieceCode, "wP")
        compare(e4Square.pieceCode, "")
        var e2Image = findChild(e2Square, "pieceImage")
        verify(e2Image !== null)
        verify(e2Image.source.toString().indexOf("/cburnett/wP.png") !== -1)
        tryCompare(e2Image, "status", Image.Ready)

        board.fen = after
        wait(0)
        compare(e2Square.pieceCode, "")
        compare(e4Square.pieceCode, "wP")
        var e4Image = findChild(e4Square, "pieceImage")
        verify(e4Image !== null)
        verify(e4Image.source.toString().indexOf("/cburnett/wP.png") !== -1)
        tryCompare(e4Image, "status", Image.Ready)
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
        compare(board.statusText, "")
        compare(board.topStatusText(), "Your move")

        board.liveFen = ""
        board.handleMessage({type: "GameStreamReconnecting"})
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
        compare(board.statusText, "You lost · Time forfeit")
        compare(board.gameReason, "Time forfeit")
        compare(board.showGameOverDialog, true)
        compare(board.topStatusText(), "")
        board.showGameOverDialog = false
        compare(board.topStatusText(), "You lost · Time forfeit")
        board.showGameOverDialog = true
        verify(findChild(board, "gameOverLoader").item !== null)
    }
}
