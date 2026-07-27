import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "BoardStyle"
    when: windowShown
    width: 600
    height: 600

    BoardStyle {
        id: style
    }

    BoardSquare {
        id: square
        width: 200
        height: 200
        pieceCode: "wK"
        pieceSet: style.pieceSet
        lightSquareColor: style.lightSquare
        darkSquareColor: style.darkSquare
        checkSquareColor: style.checkSquare
        highlightSquareColor: style.highlightSquare
        lastMoveSquareColor: style.lastMoveSquare
        premoveSquareColor: style.premoveSquare
        inkColor: style.ink
    }

    function init() {
        style.darkMode = false
        style.boardTheme = "brown"
        style.pieceSet = "cburnett"
        square.isLight = true
    }

    function test_commonOptionsAreCentralized() {
        compare(style.boardOptions.length, 4)
        compare(style.boardOptions[0].id, "brown")
        compare(style.pieceOptions.length, 3)
        compare(style.pieceOptions[1].id, "merida")
        compare(style.pieceOptions[2].id, "chessnut")
    }

    function test_paletteFlowsIntoBoardSquare() {
        style.boardTheme = "blue"
        compare(style.lightSquare, "#dce5e8")
        tryCompare(square, "color", style.lightSquare)
    }

    function test_darkPaletteKeepsBlackPiecesOffNearBlackSquares() {
        style.darkMode = true
        compare(style.lightSquare, "#b0a48e")
        compare(style.darkSquare, "#776f60")
    }

    function test_pieceSetChangesSharedAssetPath() {
        var pieceImage = findChild(square, "pieceImage")
        verify(pieceImage.source.toString().indexOf("/cburnett/wK.png") !== -1)
        style.pieceSet = "merida"
        wait(0)
        verify(pieceImage.source.toString().indexOf("/merida/wK.png") !== -1)
    }
}
