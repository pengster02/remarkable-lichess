import QtQuick 2.5

Rectangle {
    id: square
    property string squareName: ""
    property string pieceGlyph: ""
    property bool isLight: true
    property bool isHighlighted: false
    signal tapped(string squareName)

    color: isHighlighted ? "#a0c8a0" : (isLight ? "#e8e0d0" : "#8a7f6a")

    Text {
        anchors.centerIn: parent
        text: pieceGlyph
        font.pixelSize: parent.height * 0.6
    }

    MouseArea {
        anchors.fill: parent
        onClicked: square.tapped(square.squareName)
    }
}
