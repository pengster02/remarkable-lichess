import QtQuick 2.5
import net.asivery.AppLoad 1.0

Rectangle {
    id: root
    anchors.fill: parent
    // Dark backgrounds on e-ink are a real ghosting/refresh-cost tradeoff, not a free
    // win like on an OLED phone screen (see docs/remarkable-appload-platform-notes.md).
    // Deliberately using a dark warm gray rather than pure black/white for both ends
    // of the palette, everywhere in this app, to keep the pigment shift smaller.
    color: theme.background

    Theme { id: theme; darkMode: root.darkMode }

    property bool hasToken: false
    property string username: ""
    property bool darkMode: true
    // Persisted server-side (see backend/src/settings.rs) -- pushed into any
    // loaded screen that declares it, same pattern as darkMode below.
    property bool autoQueenPromotion: false
    property bool moveConfirmation: false
    property bool minimalHighlights: false
    property bool premovesEnabled: false
    property bool liveClockEnabled: true
    // Set from GameMoves right before navigating to GameReviewScreen -- same
    // hand-off pattern as darkMode/autoQueenPromotion above, since a freshly
    // Loader-created screen has no other way to receive this reply's payload.
    property var reviewMoves: []
    property var reviewFens: []
    // Aligned with reviewMoves (not reviewFens), and each may be shorter than
    // it or empty entirely -- Lichess only has clock data for timed games and
    // only has analysis for a game that's actually been through its computer
    // review (see protocol.rs's GameMoves comment).
    property var reviewClockMs: []
    property var reviewAnalysis: []
    // The tapped HistoryGameSummary itself (opponent/result/rated/speed/
    // opening/date) -- GameMoves only carries moves/fens, so this is the only
    // way GameReviewScreen's header gets to show who was played and how it
    // ended, not just a bare, contextless board.
    property var reviewGame: null

    // Bundles "remember which row was tapped" with "actually ask the backend
    // for its moves" into one call, mirroring setAutoQueenPromotion's own
    // local-state-plus-backend-send pattern -- GameHistoryScreen has no other
    // way to reach root's reviewGame property directly.
    function selectGameForReview(game) {
        root.openGameReview(game.game_id, game)
    }

    function openGameReview(gameId, game) {
        root.reviewGame = game || null
        root.sendToBackend({type: "RequestGameMoves", game_id: gameId})
    }

    function toggleDarkMode() {
        root.darkMode = !root.darkMode
    }

    // Optimistically updates root state immediately (so the toggle UI responds
    // without waiting on a round trip) -- SaveSettings's own SettingsState echo
    // (handled below) will correct this if the write actually failed.
    //
    // Every setter always sends all fields together (not just the
    // one being changed) -- SaveSettings has no partial-update semantics, so
    // sending only one previously meant toggling auto-queen silently reset
    // move_confirmation back to its serde default (false) on the backend,
    // and the same would happen to minimal_highlights if it were left out
    // here too.
    function setAutoQueenPromotion(value) {
        root.autoQueenPromotion = value
        root.sendToBackend({
            type: "SaveSettings",
            auto_queen_promotion: value,
            move_confirmation: root.moveConfirmation,
            minimal_highlights: root.minimalHighlights,
            premoves_enabled: root.premovesEnabled,
            live_clock_enabled: root.liveClockEnabled
        })
    }

    function setMoveConfirmation(value) {
        root.moveConfirmation = value
        root.sendToBackend({
            type: "SaveSettings",
            auto_queen_promotion: root.autoQueenPromotion,
            move_confirmation: value,
            minimal_highlights: root.minimalHighlights,
            premoves_enabled: root.premovesEnabled,
            live_clock_enabled: root.liveClockEnabled
        })
    }

    function setMinimalHighlights(value) {
        root.minimalHighlights = value
        root.sendToBackend({
            type: "SaveSettings",
            auto_queen_promotion: root.autoQueenPromotion,
            move_confirmation: root.moveConfirmation,
            minimal_highlights: value,
            premoves_enabled: root.premovesEnabled,
            live_clock_enabled: root.liveClockEnabled
        })
    }

    function setPremovesEnabled(value) {
        root.premovesEnabled = value
        root.sendToBackend({
            type: "SaveSettings",
            auto_queen_promotion: root.autoQueenPromotion,
            move_confirmation: root.moveConfirmation,
            minimal_highlights: root.minimalHighlights,
            premoves_enabled: value,
            live_clock_enabled: root.liveClockEnabled
        })
    }

    function setLiveClockEnabled(value) {
        root.liveClockEnabled = value
        root.sendToBackend({
            type: "SaveSettings",
            auto_queen_promotion: root.autoQueenPromotion,
            move_confirmation: root.moveConfirmation,
            minimal_highlights: root.minimalHighlights,
            premoves_enabled: root.premovesEnabled,
            live_clock_enabled: value
        })
    }

    // Screens are re-created fresh by the Loader on every navigation (Task 10's
    // pattern), so a plain one-time property push in onLoaded is enough for normal
    // navigation. But toggling dark mode happens *from inside* the currently loaded
    // screen (see HomeScreen's toggle button), so the already-loaded item's local
    // `darkMode` copy needs to be re-synced by hand when this changes underneath it.
    onDarkModeChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("darkMode")) {
            screenLoader.item.darkMode = root.darkMode
        }
    }

    // Same re-sync-the-already-loaded-screen reasoning as onDarkModeChanged --
    // SettingsScreen toggles this from inside itself, so its own local copy
    // needs to be pushed back in by hand, same as dark mode.
    onAutoQueenPromotionChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("autoQueenPromotion")) {
            screenLoader.item.autoQueenPromotion = root.autoQueenPromotion
        }
    }

    onMoveConfirmationChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("moveConfirmation")) {
            screenLoader.item.moveConfirmation = root.moveConfirmation
        }
    }

    onMinimalHighlightsChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("minimalHighlights")) {
            screenLoader.item.minimalHighlights = root.minimalHighlights
        }
    }

    onPremovesEnabledChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("premovesEnabled")) {
            screenLoader.item.premovesEnabled = root.premovesEnabled
        }
    }

    onLiveClockEnabledChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("liveClockEnabled")) {
            screenLoader.item.liveClockEnabled = root.liveClockEnabled
        }
    }

    // Required by the AppLoad host: it looks up `close`/`unloading` on the
    // root QML item (see rmpp-appload's window.qml Connections/onUnloading
    // wiring). `close` lets the app request that AppLoad tear down its
    // window; `unloading` is invoked right before AppLoad unloads this
    // frontend so it can release any resources.
    signal close
    function unloading() {
        // Nothing to release; the backend session ends when AppLoad kills
        // the backend process independently of this frontend.
    }

    AppLoad {
        id: endpoint
        applicationID: "remarkable-lichess"
        onMessageReceived: (type, contents) => {
            var msg = JSON.parse(contents)
            if (msg.type === "TokenVerified") {
                root.hasToken = true
                root.username = msg.username || ""
                endpoint.sendMessage(1, JSON.stringify({type: "RequestSettings"}))
                screenLoader.source = "HomeScreen.qml"
            } else if (msg.type === "SettingsState") {
                // Updates root state (not just forwarded to the current screen)
                // since it needs to persist across navigation, same as darkMode --
                // onAutoQueenPromotionChanged above re-syncs whatever's loaded.
                root.autoQueenPromotion = msg.auto_queen_promotion || false
                root.moveConfirmation = msg.move_confirmation || false
                root.minimalHighlights = msg.minimal_highlights || false
                root.premovesEnabled = msg.premoves_enabled || false
                root.liveClockEnabled = msg.live_clock_enabled !== undefined ? msg.live_clock_enabled : true
            } else if (msg.type === "TokenInvalid") {
                root.hasToken = false
                screenLoader.source = "SetupScreen.qml"
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "HomeState" || msg.type === "SeekCreated" || msg.type === "ChallengeCreated" || msg.type === "PendingChallenges" || msg.type === "GameHistory") {
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "GameMoves") {
                // Only reachable from GameHistoryScreen's RequestGameMoves -- an
                // ErrorMsg reply instead (bad export/replay) leaves the source
                // unchanged, so GameHistoryScreen stays up and shows it inline.
                root.reviewMoves = msg.moves || []
                root.reviewFens = msg.fens || []
                root.reviewClockMs = msg.clock_ms || []
                root.reviewAnalysis = msg.analysis || []
                screenLoader.source = "GameReviewScreen.qml"
            } else if (msg.type === "AnalysisPosition" || msg.type === "AnalysisMove" ||
                       msg.type === "CloudEvaluation" ||
                       msg.type === "CloudEvaluationUnavailable" ||
                       msg.type === "CloudEvaluationFailed") {
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "BoardState" || msg.type === "GameOver" || msg.type === "MoveRejected") {
                // Never force-navigate away from Home: a user who explicitly went
                // back to Home (or never left it yet) should stay there even if a
                // still-running per-game stream keeps delivering messages -- this
                // was the root cause of "Back to Home doesn't work" (confirmed via
                // the PC emulator: any lingering game message snapped the screen
                // back to Board with no way out). Every other screen (Setup, Seek,
                // Board itself) still auto-advances to Board normally, since that's
                // the desired flow for a freshly-started/still-loading game.
                if (screenLoader.source.toString().indexOf("HomeScreen") === -1) {
                    if (screenLoader.source.toString().indexOf("BoardScreen") === -1) {
                        screenLoader.source = "BoardScreen.qml"
                    }
                    if (screenLoader.item && screenLoader.item.handleMessage) {
                        screenLoader.item.handleMessage(msg)
                    }
                }
            } else if (msg.type === "Reconnecting" || msg.type === "OpponentGone" ||
                       msg.type === "ChatMessage" || msg.type === "ChatHistory" ||
                       msg.type === "RatingDiff" || msg.type === "Berserked") {
                // Deliberately never navigates on its own (confirmed via the PC
                // emulator: a bare Reconnecting with no real game yet threw the
                // user onto a genuinely empty, un-escapable Board screen). Only
                // ever forwarded to whichever screen is already showing.
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "ErrorMsg") {
                console.warn("Backend error: " + msg.message)
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            }
        }
    }

    function sendToBackend(obj) {
        endpoint.sendMessage(1, JSON.stringify(obj))
    }

    function navigateTo(screenName) {
        screenLoader.source = screenName
    }

    Loader {
        id: screenLoader
        anchors.fill: parent
        source: "SetupScreen.qml"
        onLoaded: {
            if (item.hasOwnProperty("backendSender")) {
                item.backendSender = root.sendToBackend
            }
            if (item.hasOwnProperty("navigateTo")) {
                item.navigateTo = root.navigateTo
            }
            if (item.hasOwnProperty("darkMode")) {
                item.darkMode = root.darkMode
            }
            if (item.hasOwnProperty("username")) {
                item.username = root.username
            }
            if (item.hasOwnProperty("toggleDarkMode")) {
                item.toggleDarkMode = root.toggleDarkMode
            }
            if (item.hasOwnProperty("autoQueenPromotion")) {
                item.autoQueenPromotion = root.autoQueenPromotion
            }
            if (item.hasOwnProperty("setAutoQueenPromotion")) {
                item.setAutoQueenPromotion = root.setAutoQueenPromotion
            }
            if (item.hasOwnProperty("moveConfirmation")) {
                item.moveConfirmation = root.moveConfirmation
            }
            if (item.hasOwnProperty("setMoveConfirmation")) {
                item.setMoveConfirmation = root.setMoveConfirmation
            }
            if (item.hasOwnProperty("minimalHighlights")) {
                item.minimalHighlights = root.minimalHighlights
            }
            if (item.hasOwnProperty("setMinimalHighlights")) {
                item.setMinimalHighlights = root.setMinimalHighlights
            }
            if (item.hasOwnProperty("premovesEnabled")) {
                item.premovesEnabled = root.premovesEnabled
            }
            if (item.hasOwnProperty("setPremovesEnabled")) {
                item.setPremovesEnabled = root.setPremovesEnabled
            }
            if (item.hasOwnProperty("liveClockEnabled")) {
                item.liveClockEnabled = root.liveClockEnabled
            }
            if (item.hasOwnProperty("setLiveClockEnabled")) {
                item.setLiveClockEnabled = root.setLiveClockEnabled
            }
            if (item.hasOwnProperty("moves")) {
                item.moves = root.reviewMoves
            }
            if (item.hasOwnProperty("fens")) {
                item.fens = root.reviewFens
            }
            if (item.hasOwnProperty("clockMs")) {
                item.clockMs = root.reviewClockMs
            }
            if (item.hasOwnProperty("analysis")) {
                item.analysis = root.reviewAnalysis
            }
            if (item.hasOwnProperty("game")) {
                item.game = root.reviewGame
            }
            if (item.hasOwnProperty("selectGameForReview")) {
                item.selectGameForReview = root.selectGameForReview
            }
            if (item.hasOwnProperty("openGameReview")) {
                item.openGameReview = root.openGameReview
            }
        }
    }

    // Visible exit affordance on every screen (one instance here in main.qml,
    // above the Loader, rather than duplicated per-screen -- every screen gets
    // it "for free" just by being loaded into this same root, which is also
    // why it's the right place to enforce it being big/consistent instead of
    // each screen reinventing its own). The host already provides a
    // swipe-down-from-top-edge -> "X" close mechanism for any fullscreen
    // AppLoad app (see docs/remarkable-appload-platform-notes.md), but it's
    // easy to miss -- this just makes the same `close()` signal reachable
    // with one direct, generously-sized tap instead.
    //
    // Right side (2026-07-21, reversed from an earlier left-side move in
    // commit 9ce618d): that earlier move was specifically to dodge the host's
    // own top-right swipe-hint affordance overlapping it. Moved back per
    // direct request -- if that overlap turns out to still be a problem on
    // real hardware, the fix belongs in *vertical* clearance (this button
    // already has plenty via theme.pageTopMargin, which every screen's
    // content also respects) or nudging this specific corner, not reverting
    // the side outright.
    Rectangle {
        id: exitButton
        width: theme.exitButtonSize
        height: theme.exitButtonSize
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: theme.exitButtonMargin
        z: 1000
        radius: theme.cardRadius
        color: theme.cardBackground
        border.width: 1
        border.color: theme.cardBorder

        Text {
            anchors.centerIn: parent
            text: "X"
            // Sized to its own now-smaller button (theme.exitButtonSize ==
            // theme.touchTarget, was a much bigger dedicated size shared with
            // nothing else) -- fontLabel, not fontHeading: a corner icon
            // reads clearly at a size well below any real content button's
            // own label, on purpose (see exitButtonSize's own comment).
            font.pixelSize: theme.fontLabel
            font.bold: true
            color: theme.text
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }
}
