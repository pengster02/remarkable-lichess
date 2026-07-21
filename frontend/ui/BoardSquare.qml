import QtQuick 2.5

Rectangle {
    id: square
    property string squareName: ""
    property string pieceGlyph: ""
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

    // Bundled instead of trusting the device's default font to contain the
    // chess Unicode block (U+2654-265F). It didn't on-device -- glyphs came
    // back as tofu/.notdef boxes, i.e. exactly "squares" where pieces should
    // be. This is a 7KB DejaVu Sans subset (see frontend/assets/, license
    // there too); pixel-checked here that all 12 codepoints resolve.
    // Relative, not "qrc:/assets/...": AppLoad mounts each app's resources.rcc
    // under a per-app namespace (confirmed on-device per scripts/build-rm.sh --
    // it requests qrc:/<app-namespace>/ui/main.qml, not qrc:/ui/main.qml), so a
    // hardcoded absolute qrc: path here would silently fail to resolve. A
    // relative path resolves against this file's own URL, namespace and all.
    FontLoader {
        id: chessFont
        source: "../assets/ChessGlyphs.ttf"
    }

    Text {
        anchors.centerIn: parent
        text: square.pieceGlyph
        font.family: chessFont.name
        font.pixelSize: parent.height * 0.6
        color: square.darkMode ? "#e6e2d8" : "black"
    }

    MouseArea {
        anchors.fill: parent
        onClicked: square.tapped(square.squareName)
    }
}
