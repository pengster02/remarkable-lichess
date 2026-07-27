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
        board.yourName = ""
        board.yourRating = null
        board.opponentName = ""
        board.opponentRating = null
    }

    function test_pageDoesNotReserveAFullExitBar() {
        compare(theme.pageTopMargin, theme.exitButtonMargin)
        verify(theme.pageTopMargin < theme.exitButtonMargin + theme.exitButtonSize)
    }

    function test_onlyTopPlayerBarClearsExitCorner() {
        var topPlayerBar = findChild(board, "topPlayerBar")
        verify(topPlayerBar !== null)
        compare(topPlayerBar.width, board.width - theme.pageSideMargin * 2 - theme.pageTopRightInset)
        compare(topPlayerBar.y, 0)
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
        compare(board.clockRefreshIntervalMs(), 5000)
        board.whiteTimeMs = 60000
        compare(board.clockRefreshIntervalMs(), 1000)
        board.initialClockMs = null
        board.firstMoveTimeMs = 30000
        compare(board.clockRefreshIntervalMs(), 1000)
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
