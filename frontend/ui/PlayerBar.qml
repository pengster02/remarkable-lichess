import QtQuick 2.5
import "qrc:/qt/qml/net/asivery/ApploadUtils"

// One side's identity + clock, shown as a full-width bar directly above or
// below the board -- the standard chess-client arrangement (lichess mobile,
// chess.com): opponent bar above, your bar below, both swapping when the
// board is flipped, active side's clock emphasized. Emphasis is a full
// invert (dark chip, light digits) plus a bold name -- a redundant,
// hue-independent cue, since color alone can't be trusted to survive this
// panel's desaturation.
Rectangle {
    id: playerBar
    property bool darkMode: false
    property string playerName: ""
    // null when there's no rating to show (AI opponents, or your own bar).
    property var rating: null
    property int clockMs: 0
    // Untimed/correspondence games have no clock to show at all.
    property bool showClock: true
    // This side is to move -- inverts the clock chip and bolds the name.
    property bool active: false
    property bool lowTime: false
    property int materialAdvantage: 0
    property var capturedPieces: []

    Theme { id: theme; darkMode: playerBar.darkMode }
    height: theme.playerBarHeight
    radius: theme.cardRadius
    color: theme.cardBackground
    border.width: playerBar.active ? 3 : 1
    border.color: playerBar.active ? theme.text : theme.cardBorder

    function formatClock(ms) {
        var totalSeconds = Math.floor(ms / 1000)
        var minutes = Math.floor(totalSeconds / 60)
        var seconds = totalSeconds % 60
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    }

    Column {
        anchors.left: parent.left
        anchors.leftMargin: theme.spacingSmall
        anchors.right: clockChip.visible ? clockChip.left : parent.right
        anchors.rightMargin: theme.spacingSmall
        anchors.verticalCenter: parent.verticalCenter
        spacing: theme.spacingXs / 2

        Text {
            width: parent.width
            text: playerBar.playerName +
                  (playerBar.rating !== null ? " (" + playerBar.rating + ")" : "") +
                  (playerBar.materialAdvantage > 0 ? "  |  +" + playerBar.materialAdvantage : "")
            font.pixelSize: theme.fontBody
            font.bold: playerBar.active
            elide: Text.ElideRight
            color: theme.text
        }

        Row {
            height: theme.fontLarge
            spacing: 2
            visible: playerBar.capturedPieces.length > 0

            Repeater {
                model: playerBar.capturedPieces
                Image {
                    required property string modelData
                    width: theme.fontLarge
                    height: width
                    source: "../assets/pieces/" + modelData + ".png"
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    sourceSize.width: width
                    sourceSize.height: height
                }
            }
        }
    }

    Rectangle {
        id: clockChip
        visible: playerBar.showClock
        anchors.right: parent.right
        anchors.rightMargin: theme.spacingXs
        anchors.verticalCenter: parent.verticalCenter
        width: theme.clockChipWidth
        height: parent.height - theme.spacingXs * 2
        radius: theme.cardRadius
        color: playerBar.active
            ? (playerBar.lowTime ? theme.errorText : theme.text)
            : "transparent"

        Text {
            id: clockText
            anchors.centerIn: parent
            text: playerBar.formatClock(playerBar.clockMs)
            font.pixelSize: theme.fontClock
            font.bold: playerBar.active || playerBar.lowTime
            color: playerBar.active
                ? theme.background
                : (playerBar.lowTime ? theme.errorText : theme.text)

            DisplayMethodArea {
                anchors.fill: parent
                displayMethod: DisplayMethodArea.Fast
            }
        }
    }

}
