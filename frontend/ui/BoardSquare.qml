import QtQuick 2.5

Rectangle {
    id: square
    property string squareName: ""
    // "wK"/"bQ"/etc, or "" for an empty square -- see BoardScreen.qml's
    // pieceCodeFor(). Matches the frontend/assets/pieces/<set>/<code>.png filenames.
    property string pieceCode: ""
    property bool isLight: true
    property bool isHighlighted: false
    property bool isSelected: false
    property bool isLegalDestination: false
    property bool isLastMove: false
    property bool isCheckSquare: false
    property bool isPremoveSource: false
    property bool isPremoveDestination: false
    property bool flashRefresh: false
    property bool darkMode: false
    property string pieceSet: "cburnett"
    property color lightSquareColor: theme.boardLightSquare
    property color darkSquareColor: theme.boardDarkSquare
    readonly property bool fastRefresh: isHighlighted || isSelected ||
        isLegalDestination || isPremoveSource || isPremoveDestination ||
        flashRefresh

    Theme { id: theme; darkMode: square.darkMode }

    // Precedence when multiple states overlap (e.g. a last-move square that's also
    // tap-selected): check > tap-selection/legal-destination > last-move > base
    // square color (see Theme.qml for the actual values and the device-panel
    // research behind them).
    color: {
        if (isCheckSquare) return theme.boardCheckSquare
        if (isHighlighted) return theme.boardHighlightSquare
        if (isPremoveSource || isPremoveDestination) return theme.boardPremoveSquare
        if (isLastMove) return theme.boardLastMoveSquare
        return isLight ? square.lightSquareColor : square.darkSquareColor
    }

    // Rasterized PNGs, not the earlier Unicode-glyph/ChessGlyphs.ttf approach.
    // Relative path for the same AppLoad
    // per-app-namespace reason as the old FontLoader source was (confirmed on
    // device per scripts/build-rm.sh): a hardcoded "qrc:/assets/..." path would
    // silently fail to resolve, a relative one resolves against this file's own
    // (namespaced) URL.
    Image {
        objectName: "pieceImage"
        anchors.centerIn: parent
        anchors.margins: parent.height * 0.06
        width: parent.width * 0.82
        height: parent.height * 0.82
        fillMode: Image.PreserveAspectFit
        visible: square.pieceCode !== ""
        source: square.pieceCode !== ""
            ? "../assets/pieces/" + square.pieceSet + "/" + square.pieceCode + ".png"
            : ""
        smooth: true
        // Decodes at the actual on-screen size (now backed by 256px source
        // art, up from 192px) instead of the source's full native
        // resolution -- avoids holding a needlessly larger decoded texture
        // per square than what's ever actually drawn.
        sourceSize.width: width
        sourceSize.height: height
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Math.max(2, parent.width * 0.05)
        color: "transparent"
        border.width: square.isCheckSquare ? Math.max(4, parent.width * 0.08)
            : (square.isSelected ? Math.max(3, parent.width * 0.06) : 0)
        border.color: theme.text
        visible: square.isCheckSquare || square.isSelected
    }

    Rectangle {
        anchors.centerIn: parent
        width: parent.width * (square.pieceCode === "" ? 0.18 : 0.76)
        height: width
        radius: width / 2
        color: square.pieceCode === "" ? theme.text : "transparent"
        border.width: square.pieceCode === "" ? 0 : Math.max(3, parent.width * 0.05)
        border.color: theme.text
        visible: square.isLegalDestination
    }

    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        width: Math.max(4, parent.width * 0.13)
        height: width
        color: theme.text
        visible: square.isLastMove
    }

    Rectangle {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: Math.max(4, parent.width * 0.13)
        height: width
        color: theme.text
        visible: square.isLastMove
    }

    Rectangle {
        anchors.fill: parent
        anchors.margins: Math.max(3, parent.width * 0.1)
        color: "transparent"
        border.width: Math.max(3, parent.width * 0.05)
        border.color: theme.text
        visible: square.isPremoveSource
    }

    Rectangle {
        anchors.centerIn: parent
        width: parent.width * 0.72
        height: Math.max(3, parent.width * 0.05)
        rotation: 45
        color: theme.text
        visible: square.isPremoveDestination
    }

    Rectangle {
        anchors.centerIn: parent
        width: parent.width * 0.72
        height: Math.max(3, parent.width * 0.05)
        rotation: -45
        color: theme.text
        visible: square.isPremoveDestination
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        visible: square.flashRefresh
    }

    EinkRefreshArea {
        anchors.fill: parent
        displayMethod: square.fastRefresh
            ? EinkRefreshArea.Fast
            : EinkRefreshArea.Content
    }
}
