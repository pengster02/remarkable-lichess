import QtQuick 2.5

SectionCard {
    id: share
    property var links: null
    property string side: "join"
    readonly property string selectedUrl: !links ? "" : side === "join"
        ? links.url : side === "white" ? links.url_white : links.url_black
    readonly property var matrix: links && links.qr_codes ? links.qr_codes[side] || null : null

    compact: true
    title: "Shareable challenge"

    readonly property Theme theme: Theme { darkMode: share.darkMode }

    // A single selected QR stays large enough to scan. Three codes compete
    // for space on the smaller tablet, and a popup hides the URL fallback.
    SegmentedControl {
        objectName: "openChallengeSide"
        darkMode: share.darkMode
        options: [
            {id: "join", label: "Any side"},
            {id: "white", label: "White"},
            {id: "black", label: "Black"}
        ]
        value: share.side
        onSelected: (value) => share.side = value
    }

    Rectangle {
        visible: share.matrix !== null
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(440, parent.width)
        height: width
        color: qr.lightColor

        QrCode {
            id: qr
            objectName: "openChallengeQr"
            anchors.centerIn: parent
            targetSize: parent.width
            moduleCount: share.matrix ? share.matrix.size : 0
            rows: share.matrix ? share.matrix.rows : []
        }
    }

    TextEdit {
        objectName: "openChallengeUrl"
        readOnly: true
        selectByMouse: true
        textFormat: TextEdit.PlainText
        width: parent.width
        wrapMode: Text.WrapAnywhere
        horizontalAlignment: Text.AlignHCenter
        font.pixelSize: theme.fontSmall
        color: theme.text
        text: share.selectedUrl
    }

    Text {
        width: parent.width
        wrapMode: Text.WordWrap
        font.pixelSize: theme.fontSmall
        color: theme.textMuted
        text: (share.matrix ? "Scan with your phone or share the link. " : "Open or share the link. ") +
            "Two players must join within 24 hours. To play here, join with the Lichess account used on this tablet."
    }
}
