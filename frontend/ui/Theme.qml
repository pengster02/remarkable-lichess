import QtQuick 2.5

// Single source of truth for color/spacing/type -- every screen reads from
// here instead of hand-copying its own hex codes/sizes. Colors are tuned for
// this device's e-ink panel (E Ink Gallery 3, warm yellow cast, shallower
// black depth than monochrome), still unverified against the real panel.
QtObject {
    id: theme
    property bool darkMode: false

    readonly property color background: darkMode ? "#2b2b28" : "#f2f0e9"
    readonly property color text: darkMode ? "#e6e2d8" : "#191817"
    readonly property color textMuted: darkMode ? "#c8c4b8" : "#403d36"

    readonly property color cardBackground: darkMode ? "#332f26" : "#e9e5d8"
    readonly property color cardBorder: darkMode ? "#5a5a55" : "#6f6a5c"
    readonly property color cardTitleText: darkMode ? "#e6e2d8" : "#22201c"
    readonly property int cardRadius: 6

    readonly property color buttonBackground: darkMode ? "#3a3a30" : "#dcd6c4"
    readonly property color buttonBorder: darkMode ? "#7a705a" : "#8a7f6a"
    readonly property color accentBackground: darkMode ? "#3a6485" : "#4f86ad"
    readonly property color accentText: "#f2ede0"

    readonly property color errorText: darkMode ? "#e2645f" : "#a03030"
    readonly property color winText: darkMode ? "#5fb865" : "#2e7d32"
    readonly property color lossText: theme.errorText
    readonly property color drawText: theme.textMuted

    // Precedence when states overlap on one square: check > selection/legal-
    // destination > last-move > base color (see BoardSquare.qml).
    readonly property color boardLightSquare: darkMode ? "#5a5648" : "#e8e0d0"
    readonly property color boardDarkSquare: darkMode ? "#211f1a" : "#5c4d3a"
    readonly property color boardCheckSquare: darkMode ? "#9c3f35" : "#d1483f"
    readonly property color boardHighlightSquare: darkMode ? "#3f7a46" : "#4f9d55"
    readonly property color boardLastMoveSquare: darkMode ? "#3a6485" : "#4f86ad"
    readonly property color boardPremoveSquare: darkMode ? "#806d2d" : "#c9a227"

    // manifest.json sets "supportsScaling": false, so 1 QML pixel = 1 real
    // screen pixel on this ~229 PPI panel -- these are scaled up accordingly.
    readonly property int spacingXs: 12
    readonly property int spacingSmall: 26
    readonly property int spacingMedium: 46
    readonly property int spacingLarge: 66

    readonly property int fontSmall: 30
    readonly property int fontLabel: 34
    readonly property int fontBody: 38
    readonly property int fontLarge: 44
    readonly property int fontTitle: 52
    readonly property int fontHeading: 64
    readonly property int fontDisplay: 76

    // The "X" exit affordance (see main.qml) -- its own smaller size class,
    // not tied to buttonMinHeight: a corner icon, not a primary action.
    readonly property int exitButtonSize: touchTarget
    readonly property int exitButtonMargin: spacingSmall

    readonly property int fontButton: 44
    readonly property int buttonPaddingV: 24
    readonly property int buttonPaddingH: 36
    readonly property int buttonMinHeight: 144

    // Shared page frame every screen anchors its content to.
    readonly property int pageTopMargin: exitButtonMargin + exitButtonSize + spacingSmall
    readonly property int pageSideMargin: spacingMedium
    readonly property int pageBottomMargin: spacingMedium

    // narrow: short numeric entry. medium: a chat message. wide: a username.
    readonly property int textFieldWidthNarrow: spacingLarge * 4
    readonly property int textFieldWidthMedium: spacingLarge * 6
    readonly property int textFieldWidthWide: spacingLarge * 10

    // ~9mm minimum finger target (81px at this panel's 229 PPI).
    readonly property int touchTarget: 96
    readonly property int listRowHeight: 120
    readonly property int boardDragThreshold: 12

    readonly property int playerBarHeight: 140
    readonly property int fontClock: 64
    readonly property int clockChipWidth: 240
}
