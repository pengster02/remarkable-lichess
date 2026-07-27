import QtQuick 2.5

Rectangle {
    id: token
    property bool darkMode: false
    property string text: ""
    property bool selected: false
    property color textColor: theme.text
    signal clicked()

    Theme { id: theme; darkMode: token.darkMode }

    width: tokenText.implicitWidth + theme.spacingSmall * 2
    height: theme.touchTarget
    radius: theme.cardRadius
    color: token.selected ? theme.accentBackground : theme.cardBackground
    border.width: token.selected ? 3 : 1
    border.color: token.selected ? theme.accentBackground : theme.cardBorder

    Text {
        id: tokenText
        anchors.centerIn: parent
        text: token.text
        font.pixelSize: theme.fontSmall
        font.bold: token.selected
        color: token.selected ? theme.accentText : token.textColor
    }

    MouseArea {
        anchors.fill: parent
        onClicked: token.clicked()
    }
}
