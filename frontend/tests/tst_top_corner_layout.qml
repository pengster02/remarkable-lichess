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
}
