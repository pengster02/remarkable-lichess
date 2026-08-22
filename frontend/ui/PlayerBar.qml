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
    property string playerTitle: ""
    // null when there's no rating to show (AI opponents, or your own bar).
    property var rating: null
    property bool provisional: false
    property string presenceText: ""
    property bool streaming: false
    property bool patron: false
    property string flair: ""
    property string identityDetailText: playerBar.buildIdentityDetails()
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

    function flairLabel(value) {
        if (!value || value.length === 0) return ""
        var slug = value.substring(value.lastIndexOf(".") + 1)
        var words = slug.split("-")
        if (words.length === 0) return ""
        words[0] = words[0].charAt(0).toUpperCase() + words[0].substring(1)
        return words.join(" ")
    }

    function buildIdentityDetails() {
        var details = []
        if (playerBar.rating !== null) {
            details.push("(" + playerBar.rating + (playerBar.provisional ? "?" : "") + ")")
        }
        if (playerBar.presenceText.length > 0) details.push(playerBar.presenceText)
        if (playerBar.streaming) details.push("Live")
        if (playerBar.patron) details.push("Patron")
        var flairName = playerBar.flairLabel(playerBar.flair)
        if (flairName.length > 0) details.push(flairName)
        return details.join("  ·  ")
    }

    Theme { id: theme; darkMode: playerBar.darkMode }
    height: theme.playerBarHeight
    radius: theme.cardRadius
    color: theme.cardBackground
    border.width: 1
    border.color: theme.cardBorder

    Rectangle {
        visible: playerBar.active
        anchors.left: parent.left
        anchors.leftMargin: theme.spacingXs / 2
        anchors.top: parent.top
        anchors.topMargin: theme.spacingXs
        anchors.bottom: parent.bottom
        anchors.bottomMargin: theme.spacingXs
        width: theme.sectionRailWidth
        radius: width / 2
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

        Row {
            width: parent.width
            height: theme.fontLarge
            spacing: playerBar.playerTitle.length > 0 ? theme.spacingXs : 0

            Rectangle {
                visible: playerBar.playerTitle.length > 0
                width: visible ? titleLabel.implicitWidth + theme.spacingXs : 0
                height: parent.height
                radius: theme.cardRadius / 2
                color: "transparent"
                border.width: 1
                border.color: theme.text

                Text {
                    id: titleLabel
                    objectName: "playerTitleText"
                    anchors.centerIn: parent
                    text: playerBar.playerTitle
                    font.pixelSize: theme.fontSmall
                    font.bold: true
                    font.letterSpacing: 1
                    color: theme.text
                }
            }

            Text {
                objectName: "playerNameText"
                width: parent.width - x
                height: parent.height
                verticalAlignment: Text.AlignVCenter
                text: playerBar.playerName +
                      (playerBar.identityDetailText.length > 0
                          ? "  " + playerBar.identityDetailText
                          : "") +
                      (playerBar.materialAdvantage > 0 ? "  |  +" + playerBar.materialAdvantage : "")
                font.pixelSize: theme.fontLabel
                font.bold: playerBar.opponent
                elide: Text.ElideRight
                color: theme.text
            }
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
