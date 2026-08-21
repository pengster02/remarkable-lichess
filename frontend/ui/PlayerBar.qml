import QtQuick 2.5

// One side's identity + clock, shown as a full-width bar directly above or
// below the board -- the standard chess-client arrangement (lichess mobile,
// chess.com): opponent bar above, your bar below, both swapping when the
// board is flipped, active side's clock emphasized. The colored rail is the
// turn signal; the clock inversion remains legible when color is desaturated.
Rectangle {
    id: playerBar
    property bool darkMode: false
    property string playerName: ""
    // null when there's no rating to show (AI opponents, or your own bar).
    property var rating: null
    property int clockMs: 0
    // Untimed/correspondence games have no clock to show at all.
    property bool showClock: true
    // This side is to move -- marks the rail and inverts the clock chip.
    property bool active: false
    property bool opponent: false
    property bool lowTime: false
    property int materialAdvantage: 0
    property var capturedPieces: []
    property string statusText: ""
    property bool statusEmphasized: false
    property string pieceSet: "cburnett"

    Theme { id: theme; darkMode: playerBar.darkMode }
    height: theme.playerBarHeight
    radius: theme.cardRadius
    clip: true
    color: theme.cardBackground
    border.width: 1
    border.color: theme.cardBorder

    Rectangle {
        visible: playerBar.active
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: theme.sectionRailWidth
        color: playerBar.lowTime ? theme.errorText : theme.accentBackground
    }

    function formatClock(ms) {
        var totalSeconds = Math.floor(ms / 1000)
        var minutes = Math.floor(totalSeconds / 60)
        var seconds = totalSeconds % 60
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    }

    Column {
        anchors.left: parent.left
        anchors.leftMargin: theme.spacingSmall +
            (playerBar.active ? theme.sectionRailWidth : 0)
        anchors.right: clockChip.visible ? clockChip.left : parent.right
        anchors.rightMargin: theme.spacingSmall
        anchors.verticalCenter: parent.verticalCenter
        spacing: theme.spacingXs / 2

        Text {
            objectName: "playerNameText"
            width: parent.width
            text: playerBar.playerName +
                  (playerBar.rating !== null ? " (" + playerBar.rating + ")" : "") +
                  (playerBar.materialAdvantage > 0 ? "  |  +" + playerBar.materialAdvantage : "")
            font.pixelSize: theme.fontLabel
            font.bold: playerBar.opponent
            elide: Text.ElideRight
            color: theme.text
        }

        Row {
            height: theme.fontLarge
            width: parent.width
            spacing: theme.spacingXs
            visible: playerBar.statusText.length > 0 ||
                playerBar.capturedPieces.length > 0

            Text {
                objectName: "playerStatusText"
                visible: playerBar.statusText.length > 0
                width: visible
                    ? Math.min(
                        implicitWidth,
                        parent.width - capturedPiecesRow.width -
                            (capturedPiecesRow.visible ? theme.spacingXs : 0)
                    )
                    : 0
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: playerBar.statusText
                font.pixelSize: theme.fontLabel
                font.bold: playerBar.statusEmphasized
                elide: Text.ElideRight
                color: theme.text

                EinkRefreshArea {
                    anchors.fill: parent
                    displayMethod: EinkRefreshArea.Fast
                }
            }

            Row {
                id: capturedPiecesRow
                height: parent.height
                spacing: 2
                visible: playerBar.capturedPieces.length > 0

                Repeater {
                    model: playerBar.capturedPieces
                    Image {
                        required property string modelData
                        width: theme.fontLarge
                        height: width
                        source: "../assets/pieces/" + playerBar.pieceSet + "/" + modelData + ".png"
                        fillMode: Image.PreserveAspectFit
                        smooth: false
                        sourceSize.width: width
                        sourceSize.height: height
                    }
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
            font.bold: playerBar.lowTime
            color: playerBar.active
                ? theme.background
                : (playerBar.lowTime ? theme.errorText : theme.text)
        }

        EinkRefreshArea {
            anchors.fill: parent
            // Only the side to move is ticking locally; keep the idle chip on
            // Content so turn swaps still look clean without Fast chatter.
            displayMethod: playerBar.active
                ? EinkRefreshArea.Fast
                : EinkRefreshArea.Content
        }
    }

}
