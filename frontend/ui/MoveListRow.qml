import QtQuick 2.5

Item {
    id: moveRow
    property bool darkMode: false
    property int moveNumber: 1
    property var whiteMove: null
    property var blackMove: null
    property int currentIndex: 0
    signal moveSelected(int fenIndex)

    Theme { id: theme; darkMode: moveRow.darkMode }

    readonly property bool hasClock:
        (whiteMove && whiteMove.clockLabel && whiteMove.clockLabel.length > 0) ||
        (blackMove && blackMove.clockLabel && blackMove.clockLabel.length > 0)
    readonly property int numberColumnWidth: theme.touchTarget

    height: hasClock ? 128 : theme.touchTarget

    Row {
        id: columns
        anchors.fill: parent
        spacing: theme.spacingXs

        Text {
            id: moveNumberLabel
            objectName: "moveNumberLabel"
            width: moveRow.numberColumnWidth
            height: parent.height
            text: moveRow.moveNumber + "."
            font.pixelSize: theme.fontSmall
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: theme.textMuted
        }

        MoveListCell {
            objectName: "whiteMoveCell"
            mouseObjectName: "whiteMoveMouseArea"
            width: (columns.width - moveRow.numberColumnWidth - theme.spacingXs * 2) / 2
            height: columns.height
            darkMode: moveRow.darkMode
            moveData: moveRow.whiteMove
            currentIndex: moveRow.currentIndex
            onSelected: (fenIndex) => moveRow.moveSelected(fenIndex)
        }

        MoveListCell {
            objectName: "blackMoveCell"
            mouseObjectName: "blackMoveMouseArea"
            width: (columns.width - moveRow.numberColumnWidth - theme.spacingXs * 2) / 2
            height: columns.height
            darkMode: moveRow.darkMode
            moveData: moveRow.blackMove
            currentIndex: moveRow.currentIndex
            onSelected: (fenIndex) => moveRow.moveSelected(fenIndex)
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 1
        color: theme.divider
    }
}
