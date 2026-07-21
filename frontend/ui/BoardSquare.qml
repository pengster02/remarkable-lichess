import QtQuick 2.5

Rectangle {
    id: square
    property string squareName: ""
    // "wK"/"bQ"/etc, or "" for an empty square -- see BoardScreen.qml's
    // pieceCodeFor(). Matches the frontend/assets/pieces/<code>.png filenames.
    property string pieceCode: ""
    property bool isLight: true
    property bool isHighlighted: false
    property bool isLastMove: false
    property bool isCheckSquare: false
    property bool darkMode: false
    signal tapped(string squareName)

    // Precedence when multiple states overlap (e.g. a last-move square that's also
    // tap-selected): check > tap-selection/legal-destination > last-move > base
    // square color. Dark-mode palette deliberately avoids pure black/white -- see
    // the note in main.qml. Same hue relationships as the light palette across all
    // four states, just shifted darker overall. Unverified against real e-ink
    // ghosting/refresh behavior; needs an on-device (or at least PC-emulator) look
    // before calling any of these colors final.
    color: {
        if (isCheckSquare) return darkMode ? "#8a3a3a" : "#e07a7a"
        if (isHighlighted) return darkMode ? "#4f6b4f" : "#a0c8a0"
        if (isLastMove) return darkMode ? "#4a5a66" : "#b8d0e0"
        return darkMode ? (isLight ? "#5a5648" : "#211f1a") : (isLight ? "#e8e0d0" : "#8a7f6a")
    }

    // Rasterized cburnett PNGs (see frontend/assets/pieces/LICENSE-cburnett.txt),
    // not the earlier Unicode-glyph/ChessGlyphs.ttf approach -- real piece art
    // instead of text-rendered symbols. Relative path for the same AppLoad
    // per-app-namespace reason as the old FontLoader source was (confirmed on
    // device per scripts/build-rm.sh): a hardcoded "qrc:/assets/..." path would
    // silently fail to resolve, a relative one resolves against this file's own
    // (namespaced) URL.
    Image {
        anchors.centerIn: parent
        anchors.margins: parent.height * 0.06
        width: parent.width * 0.82
        height: parent.height * 0.82
        fillMode: Image.PreserveAspectFit
        visible: square.pieceCode !== ""
        source: square.pieceCode !== "" ? "../assets/pieces/" + square.pieceCode + ".png" : ""
        smooth: true
    }

    MouseArea {
        anchors.fill: parent
        onClicked: square.tapped(square.squareName)
    }
}
