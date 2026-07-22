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

    Theme { id: theme; darkMode: square.darkMode }

    // Precedence when multiple states overlap (e.g. a last-move square that's also
    // tap-selected): check > tap-selection/legal-destination > last-move > base
    // square color (see Theme.qml for the actual values and the device-panel
    // research behind them).
    color: {
        if (isCheckSquare) return theme.boardCheckSquare
        if (isHighlighted) return theme.boardHighlightSquare
        if (isLastMove) return theme.boardLastMoveSquare
        return isLight ? theme.boardLightSquare : theme.boardDarkSquare
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
        // Decodes at the actual on-screen size (now backed by 256px source
        // art, up from 192px) instead of the source's full native
        // resolution -- avoids holding a needlessly larger decoded texture
        // per square than what's ever actually drawn.
        sourceSize.width: width
        sourceSize.height: height
    }

    MouseArea {
        anchors.fill: parent
        onClicked: square.tapped(square.squareName)
    }
}
