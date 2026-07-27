import QtQuick 2.5

// Single source of truth for color/spacing/type -- every screen reads from
// here instead of hand-copying its own hex codes/sizes. Colors are tuned for
// this device's e-ink panel (E Ink Gallery 3, warm yellow cast, shallower
// black depth than monochrome), still unverified against the real panel.
QtObject {
    id: theme
    property bool darkMode: false

    readonly property color background: darkMode ? "#302f2b" : "#f2f0e9"
    readonly property color text: darkMode ? "#f5f0e5" : "#191817"
    readonly property color textMuted: darkMode ? "#cfc8ba" : "#403d36"

    readonly property color cardBackground: darkMode ? "#47443c" : "#e9e5d8"
    readonly property color cardBorder: darkMode ? "#9b9384" : "#6f6a5c"
    readonly property color cardTitleText: darkMode ? "#f5f0e5" : "#22201c"
    readonly property int cardRadius: 6

    readonly property color buttonBackground: darkMode ? "#5b564b" : "#dcd6c4"
    readonly property color buttonBorder: darkMode ? "#a79e8d" : "#8a7f6a"
    readonly property color accentBackground: darkMode ? "#527b9d" : "#396b92"
    readonly property color accentText: "#f2ede0"
    readonly property color criticalBackground: "#74312d"
    readonly property color criticalText: "#fff8ec"

    readonly property color errorText: darkMode ? "#f08076" : "#a03030"
    readonly property color winText: darkMode ? "#7dcc82" : "#2e7d32"
    readonly property color lossText: theme.errorText
    readonly property color drawText: theme.textMuted

    // Precedence when states overlap on one square: check > selection/legal-
    // destination > last-move > base color (see BoardSquare.qml).
    readonly property color boardLightSquare: darkMode ? "#b0a48e" : "#e8e0d0"
    readonly property color boardDarkSquare: darkMode ? "#776f60" : "#5c4d3a"
    readonly property color boardCheckSquare: darkMode ? "#b95b4f" : "#d1483f"
    readonly property color boardHighlightSquare: darkMode ? "#66946a" : "#4f9d55"
    readonly property color boardLastMoveSquare: darkMode ? "#6286a3" : "#4f86ad"
    readonly property color boardPremoveSquare: darkMode ? "#a48d43" : "#c9a227"

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

    // Persistent top bar (main.qml): always-on connection status + Exit, spanning
    // the full width above every screen -- replaces the old corner "X" square.
    readonly property int topBarHeight: touchTarget

    readonly property int fontButton: 44
    readonly property int buttonPaddingV: 24
    readonly property int buttonPaddingH: 36
    readonly property int buttonMinHeight: 144

    readonly property int pageSideMargin: spacingMedium
    readonly property int pageTopMargin: exitButtonMargin
    // Was a right-edge inset so screen content dodged the old corner "X". The X is
    // gone (the persistent top bar spans the full width instead), so nothing needs
    // dodging -- kept as 0 so the screens that still subtract it stay full-width.
    readonly property int pageTopRightInset: 0
    readonly property int pageBottomMargin: spacingMedium

    // narrow: short numeric entry. medium: compact action. wide: a username.
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
