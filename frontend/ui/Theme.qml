import QtQuick 2.5

// Single source of truth for color/spacing/type, so every screen reads the
// same values instead of each hand-copying its own near-duplicate hex codes
// (confirmed drift: main.qml/GameHistoryScreen/BoardScreen each had a
// slightly different "card" color before this existed). Values here match
// the repaint already applied to BoardSquare.qml/SectionCard.qml -- real
// research into this device's actual panel (E Ink Gallery 3 / Paper Pro
// Move: a 4-pigment CMYW system with a warm yellow cast and shallower black
// depth than a monochrome panel), so colors are cool-neutral and pulled
// toward genuine saturation rather than pastel, since the panel desaturates
// everything further on its own. Still unverified against the real panel.
QtObject {
    id: theme
    property bool darkMode: false

    readonly property color background: darkMode ? "#2b2b28" : "#eef1f0"
    readonly property color text: darkMode ? "#e6e2d8" : "#15181a"
    readonly property color textMuted: darkMode ? "#c8c4b8" : "#555550"

    readonly property color cardBackground: darkMode ? "#332f26" : "#e2e7e6"
    readonly property color cardBorder: darkMode ? "#5a5a55" : "#6b7472"
    readonly property color cardTitleText: darkMode ? "#e6e2d8" : "#1f2422"
    readonly property int cardRadius: 6

    // Button chrome -- same blue family as BoardSquare's isHighlighted/selected
    // state, so a "selected" toggle button (Color: White/Black/Random, the
    // history filters) reads as the same kind of selected/active state as a
    // selected board square, not an unrelated one-off color.
    readonly property color buttonBackground: darkMode ? "#3a3a30" : "#dcd6c4"
    readonly property color buttonBorder: darkMode ? "#7a705a" : "#8a7f6a"
    readonly property color buttonPressedBackground: darkMode ? "#4a4838" : "#c8c0a8"
    readonly property color accentBackground: darkMode ? "#3a6485" : "#4f86ad"
    readonly property color accentText: "#f2ede0"

    // Same red family as BoardSquare's isCheckSquare, pulled toward
    // saturation rather than pastel for the same panel-desaturation reason.
    readonly property color errorText: darkMode ? "#e2645f" : "#a03030"
    readonly property color winText: darkMode ? "#5fb865" : "#2e7d32"
    readonly property color lossText: theme.errorText
    readonly property color drawText: theme.textMuted

    // Precedence when multiple states overlap on one square: check > tap-
    // selection/legal-destination > last-move > base square color (see
    // BoardSquare.qml). Light/dark square gap deliberately widened (deep
    // walnut, not a subtle medium brown) per the same panel research above.
    readonly property color boardLightSquare: darkMode ? "#5a5648" : "#e8e0d0"
    readonly property color boardDarkSquare: darkMode ? "#211f1a" : "#5c4d3a"
    readonly property color boardCheckSquare: darkMode ? "#9c3f35" : "#d1483f"
    readonly property color boardHighlightSquare: darkMode ? "#3f7a46" : "#4f9d55"
    readonly property color boardLastMoveSquare: darkMode ? "#3a6485" : "#4f86ad"

    // This device (reMarkable "Chiappa"/Paper Pro, ~229 PPI) sets
    // "supportsScaling": false in manifest.json -- AppLoad applies no
    // automatic DPI scaling, so 1 QML pixel is 1 real screen pixel. Every
    // value below is scaled roughly 2.2x versus what would read as normal
    // size on a typical ~96 PPI reference display, or text/controls render
    // visibly undersized on the real panel (confirmed live).
    //
    // Bumped again (2026-07-21) on top of that first pass -- live feedback
    // was "still too small" even after the above, so these are now scaled
    // closer to 2.7x instead of 2.2x. If a future on-device pass says this
    // overshot, scale this block down rather than hand-tuning individual
    // screens back to hardcoded numbers -- the whole point of this file
    // existing is that every screen reads from here, never its own guess.
    readonly property int spacingXs: 12
    readonly property int spacingSmall: 26
    readonly property int spacingMedium: 46
    readonly property int spacingLarge: 66

    readonly property int fontSmall: 38
    readonly property int fontLabel: 44
    readonly property int fontBody: 50
    readonly property int fontLarge: 58
    readonly property int fontTitle: 68
    readonly property int fontHeading: 86
    readonly property int fontDisplay: 100

    // The single "X" exit affordance every screen shares (see main.qml) --
    // named here (not just inlined literals in main.qml) because pageTopMargin
    // below is *derived* from it: every screen's content has to clear this
    // button vertically regardless of which corner it's anchored to, so this
    // is the one place that relationship is expressed, instead of each screen
    // guessing its own "big enough" number (confirmed real drift before this:
    // BoardScreen/GameHistoryScreen/GameReviewScreen each hardcoded a bare
    // `72`, HomeScreen used `spacingLarge * 2`, and Seek/Settings/Setup used
    // no top margin at all via `anchors.centerIn: parent` -- three different,
    // silently-drifting answers to the same question).
    readonly property int exitButtonSize: 110
    readonly property int exitButtonMargin: spacingSmall

    // The shared page frame every screen anchors its own content to (see each
    // screen's outermost Item/Column/Flickable) -- this is the "shared frame"
    // itself: one definition of the safe content area's insets, not a visual
    // wrapper component (a real wrapper wasn't worth the cross-file QML id-
    // scope risk here, given there's no toolchain in this dev loop to catch a
    // mistake before it ships -- see docs/remarkable-appload-platform-notes.md's
    // own note on QML being unverifiable here beyond careful inspection).
    // pageTopMargin clears the exit button with a little breathing room below
    // it, regardless of which corner the button lives in -- clearing it
    // vertically has always been enough (the button only occupies one corner
    // horizontally either way), so there's deliberately no separate "avoid the
    // right side" carve-out.
    readonly property int pageTopMargin: exitButtonMargin + exitButtonSize + spacingSmall
    readonly property int pageSideMargin: spacingMedium
    readonly property int pageBottomMargin: spacingMedium

    // TextField widths, derived from spacingLarge rather than each field's
    // own hand-picked literal (220/340/560 before this existed) -- those
    // literals were tuned against an earlier, smaller version of this same
    // scale and never got revisited across either of the two bumps above,
    // exactly the kind of silent drift this file exists to prevent
    // elsewhere. narrow: short numeric entry (minutes/increment/AI level).
    // medium: a chat message. wide: a Lichess username.
    readonly property int textFieldWidthNarrow: spacingLarge * 4
    readonly property int textFieldWidthMedium: spacingLarge * 6
    readonly property int textFieldWidthWide: spacingLarge * 10
}
