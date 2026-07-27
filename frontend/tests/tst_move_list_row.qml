import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    id: testCase
    name: "MoveListRow"
    when: windowShown
    width: 840
    height: 400

    MoveListRow {
        id: moveRow
        width: parent.width
        moveNumber: 12
        whiteMove: ({san: "Nxf7?!", fenIndex: 23, clockLabel: "8:42", judgment: "Inaccuracy"})
        blackMove: ({san: "Kxf7", fenIndex: 24, clockLabel: "8:31", judgment: null})
        currentIndex: 23
    }

    SignalSpy {
        id: moveSelectedSpy
        target: moveRow
        signalName: "moveSelected"
    }

    function init() {
        moveSelectedSpy.clear()
        moveRow.whiteMove = {
            san: "Nxf7?!", fenIndex: 23, clockLabel: "8:42", judgment: "Inaccuracy"
        }
        moveRow.blackMove = {
            san: "Kxf7", fenIndex: 24, clockLabel: "8:31", judgment: null
        }
        moveRow.currentIndex = 23
        wait(0)
    }

    function test_scoreSheetUsesEqualMoveColumns() {
        var number = findChild(moveRow, "moveNumberLabel")
        var white = findChild(moveRow, "whiteMoveCell")
        var black = findChild(moveRow, "blackMoveCell")
        verify(number !== null)
        verify(white !== null)
        verify(black !== null)
        compare(number.text, "12.")
        compare(white.width, black.width)
        verify(number.mapToItem(moveRow, 0, 0).x < white.mapToItem(moveRow, 0, 0).x)
        verify(white.mapToItem(moveRow, 0, 0).x < black.mapToItem(moveRow, 0, 0).x)
    }

    function test_currentMoveAndSelectionNavigation() {
        var white = findChild(moveRow, "whiteMoveCell")
        var black = findChild(moveRow, "blackMoveCell")
        compare(white.isCurrent, true)
        compare(black.isCurrent, false)
        black.selected(24)
        compare(moveSelectedSpy.count, 1)
        compare(moveSelectedSpy.signalArguments[0][0], 24)
    }

    function test_missingBlackMoveLeavesAnEmptyCell() {
        moveRow.blackMove = null
        wait(0)
        var black = findChild(moveRow, "blackMoveCell")
        compare(black.hasMove, false)
    }
}
