import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "BoardSquareRefresh"
    when: windowShown
    width: 400
    height: 400

    BoardSquare {
        id: square
        width: 200
        height: 200
    }

    function init() {
        square.isHighlighted = false
        square.isSelected = false
        square.isLegalDestination = false
        square.isPremoveSource = false
        square.isPremoveDestination = false
        square.flashRefresh = false
        square.isLastMove = false
    }

    function test_idlePositionUsesContentRefresh() {
        compare(square.fastRefresh, false)
        square.isLastMove = true
        compare(square.fastRefresh, false)
    }

    function test_interactionStatesUseFastRefresh() {
        square.isSelected = true
        compare(square.fastRefresh, true)
        square.isSelected = false
        square.isLegalDestination = true
        compare(square.fastRefresh, true)
        square.isLegalDestination = false
        square.isPremoveDestination = true
        compare(square.fastRefresh, true)
    }

    function test_clearPulseUsesFastRefresh() {
        square.flashRefresh = true
        compare(square.fastRefresh, true)
        square.flashRefresh = false
        compare(square.fastRefresh, false)
    }

    function test_clearPulseOpposesCanvasPolarity() {
        square.darkMode = false
        compare(square.refreshFlashColor, "#111111")
        square.darkMode = true
        compare(square.refreshFlashColor, "#fffdf7")
    }
}
