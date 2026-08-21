import QtQuick 2.5

Rectangle {
    id: moveCell
    property bool darkMode: false
    property var moveData: null
    property int currentIndex: 0
    property string mouseObjectName: ""
    signal selected(int fenIndex)

    Theme { id: theme; darkMode: moveCell.darkMode }

    readonly property bool hasMove: moveData !== null && moveData !== undefined
    readonly property bool isCurrent: hasMove && moveData.fenIndex === currentIndex

    radius: theme.compactControlRadius
    color: moveCellMouse.pressed
        ? theme.text
        : (isCurrent ? theme.accentBackground : "transparent")
    border.width: isCurrent ? 3 : 0
    border.color: isCurrent ? theme.accentBackground : "transparent"

    function judgmentColor(judgment) {
        if (judgment === "Blunder") return theme.errorText
        if (judgment === "Mistake") return theme.lossText
        if (judgment === "Inaccuracy") return theme.textMuted
        return theme.text
    }

    Column {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: theme.spacingXs
        spacing: 2

        Text {
            width: parent.width
            text: moveCell.hasMove ? moveCell.moveData.san : ""
            font.pixelSize: theme.fontBody
            font.bold: moveCell.isCurrent
            elide: Text.ElideRight
            color: moveCellMouse.pressed
                ? theme.background
                : (moveCell.isCurrent
                    ? theme.accentText
                    : moveCell.judgmentColor(
                        moveCell.hasMove ? moveCell.moveData.judgment : null
                    ))
        }

        Text {
            width: parent.width
            visible: moveCell.hasMove &&
                     moveCell.moveData.clockLabel &&
                     moveCell.moveData.clockLabel.length > 0
            text: visible ? moveCell.moveData.clockLabel : ""
            font.pixelSize: theme.fontSmall
            color: moveCellMouse.pressed
                ? theme.background
                : (moveCell.isCurrent ? theme.accentText : theme.textMuted)
        }
    }

    EinkRefreshArea {
        anchors.fill: parent
        displayMethod: moveCellMouse.pressed
            ? EinkRefreshArea.Fast
            : EinkRefreshArea.UI
    }

    MouseArea {
        id: moveCellMouse
        objectName: moveCell.mouseObjectName
        anchors.fill: parent
        enabled: moveCell.hasMove
        onClicked: moveCell.selected(moveCell.moveData.fenIndex)
    }
}
