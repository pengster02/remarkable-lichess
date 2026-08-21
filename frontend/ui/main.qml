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
    property bool darkMode: false
    // Persisted server-side (see backend/src/settings.rs) -- pushed into any
    // loaded screen that declares it, same pattern as darkMode below.
    property bool autoQueenPromotion: false
    property bool moveConfirmation: false
    property bool minimalHighlights: true
    property bool premovesEnabled: false
    property bool liveClockEnabled: true
    property string boardTheme: "brown"
    property string pieceSet: "cburnett"
    property bool showCoordinates: true
    property bool showCapturedPieces: true
    property bool highlightLastMove: true
    property bool confirmResign: false
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

    // Connectivity lives at the root (not per-screen) so the persistent top bar
    // can show it on every screen -- fed by the backend's ConnectivityState (see
    // the message router below and backend_app.rs's wifi_link_state).
    property bool connectivityKnown: false
    property bool online: false
    property var wifiConnected: null
    property string connectionMessage: ""

    function connectivityLabel() {
        if (!root.connectivityKnown) return "Connecting…"
        if (root.online) return "Online"
        if (root.wifiConnected === false) return "Offline — Wi-Fi disconnected"
        return "Offline — Lichess unreachable"
    }

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

    function persistSettings() {
        root.sendToBackend({
            type: "SaveSettings",
            auto_queen_promotion: root.autoQueenPromotion,
            move_confirmation: root.moveConfirmation,
            minimal_highlights: root.minimalHighlights,
            premoves_enabled: root.premovesEnabled,
            live_clock_enabled: root.liveClockEnabled,
            board_theme: root.boardTheme,
            piece_set: root.pieceSet,
            show_coordinates: root.showCoordinates,
            show_captured_pieces: root.showCapturedPieces,
            highlight_last_move: root.highlightLastMove,
            confirm_resign: root.confirmResign
        })
    }

    function setAutoQueenPromotion(value) {
        root.autoQueenPromotion = value
        root.persistSettings()
    }

    function setMoveConfirmation(value) {
        root.moveConfirmation = value
        root.persistSettings()
    }

    function setMinimalHighlights(value) {
        root.minimalHighlights = value
        root.persistSettings()
    }

    function setPremovesEnabled(value) {
        root.premovesEnabled = value
        root.persistSettings()
    }

    function setLiveClockEnabled(value) {
        root.liveClockEnabled = value
        root.persistSettings()
    }

    function setBoardTheme(value) {
        root.boardTheme = value
        root.persistSettings()
    }

    function setPieceSet(value) {
        root.pieceSet = value
        root.persistSettings()
    }

    function setShowCoordinates(value) {
        root.showCoordinates = value
        root.persistSettings()
    }

    function setShowCapturedPieces(value) {
        root.showCapturedPieces = value
        root.persistSettings()
    }

    function setHighlightLastMove(value) {
        root.highlightLastMove = value
        root.persistSettings()
    }

    function setConfirmResign(value) {
        root.confirmResign = value
        root.persistSettings()
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

    onBoardThemeChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("boardTheme")) {
            screenLoader.item.boardTheme = root.boardTheme
        }
    }

    onPieceSetChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("pieceSet")) {
            screenLoader.item.pieceSet = root.pieceSet
        }
    }

    onShowCoordinatesChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("showCoordinates")) {
            screenLoader.item.showCoordinates = root.showCoordinates
        }
    }

    onShowCapturedPiecesChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("showCapturedPieces")) {
            screenLoader.item.showCapturedPieces = root.showCapturedPieces
        }
    }

    onHighlightLastMoveChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("highlightLastMove")) {
            screenLoader.item.highlightLastMove = root.highlightLastMove
        }
    }

    onConfirmResignChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("confirmResign")) {
            screenLoader.item.confirmResign = root.confirmResign
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
                root.minimalHighlights = msg.minimal_highlights !== undefined
                    ? msg.minimal_highlights
                    : true
                root.premovesEnabled = msg.premoves_enabled || false
                root.liveClockEnabled = msg.live_clock_enabled !== undefined ? msg.live_clock_enabled : true
                root.boardTheme = msg.board_theme || "brown"
                root.pieceSet = msg.piece_set || "cburnett"
                root.showCoordinates = msg.show_coordinates !== undefined ? msg.show_coordinates : true
                root.showCapturedPieces = msg.show_captured_pieces !== undefined ? msg.show_captured_pieces : true
                root.highlightLastMove = msg.highlight_last_move !== undefined ? msg.highlight_last_move : true
                root.confirmResign = msg.confirm_resign || false
            } else if (msg.type === "TokenInvalid") {
                root.hasToken = false
                screenLoader.source = "LoginScreen.qml"
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "LoginCompleted") {
                // The backend's sign-in task only got as far as saving the
                // token; asking for it to be activated has to come from here
                // because that task can't touch the backend's own state (see
                // protocol.rs's ActivateSavedToken).
                root.sendToBackend({type: "ActivateSavedToken"})
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "LoginChallenge" || msg.type === "LoginFailed") {
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "ConnectivityState") {
                // Owned by the root so the persistent top bar shows it everywhere;
                // still forwarded to the current screen, which uses it for its own
                // retry/error logic (see HomeScreen.handleMessage).
                root.connectivityKnown = true
                root.online = msg.online || false
                root.wifiConnected = msg.wifi_connected !== undefined
                    ? msg.wifi_connected
                    : null
                root.connectionMessage = msg.message || ""
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "HomeState" || msg.type === "HomeLoadFailed" ||
                       msg.type === "SeekCreated" || msg.type === "ChallengeCreated" ||
                       msg.type === "PendingChallenges" ||
                       msg.type === "ChallengesLoadFailed" ||
                       msg.type === "GameHistory") {
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
            } else if (msg.type === "GameStreamReconnecting" || msg.type === "OpponentGone" ||
                       msg.type === "RatingDiff" || msg.type === "GameActionCompleted" ||
                       msg.type === "MovePreview" || msg.type === "MoveSubmitted") {
                // Deliberately never navigates on its own (confirmed via the PC
                // emulator: a bare reconnect message with no real game yet threw the
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
        // Sits below the persistent top bar so no screen underlaps it.
        anchors.top: topBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        source: "LoginScreen.qml"
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
            if (item.hasOwnProperty("boardTheme")) {
                item.boardTheme = root.boardTheme
            }
            if (item.hasOwnProperty("setBoardTheme")) {
                item.setBoardTheme = root.setBoardTheme
            }
            if (item.hasOwnProperty("pieceSet")) {
                item.pieceSet = root.pieceSet
            }
            if (item.hasOwnProperty("setPieceSet")) {
                item.setPieceSet = root.setPieceSet
            }
            if (item.hasOwnProperty("showCoordinates")) {
                item.showCoordinates = root.showCoordinates
            }
            if (item.hasOwnProperty("setShowCoordinates")) {
                item.setShowCoordinates = root.setShowCoordinates
            }
            if (item.hasOwnProperty("showCapturedPieces")) {
                item.showCapturedPieces = root.showCapturedPieces
            }
            if (item.hasOwnProperty("setShowCapturedPieces")) {
                item.setShowCapturedPieces = root.setShowCapturedPieces
            }
            if (item.hasOwnProperty("highlightLastMove")) {
                item.highlightLastMove = root.highlightLastMove
            }
            if (item.hasOwnProperty("setHighlightLastMove")) {
                item.setHighlightLastMove = root.setHighlightLastMove
            }
            if (item.hasOwnProperty("confirmResign")) {
                item.confirmResign = root.confirmResign
            }
            if (item.hasOwnProperty("setConfirmResign")) {
                item.setConfirmResign = root.setConfirmResign
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

    // Persistent status bar on every screen (one instance here at the root, above
    // the Loader): always-on connection status, nothing tappable. There is no
    // in-app exit button by design -- the host closes any fullscreen AppLoad app
    // via its own swipe-down-from-top-edge gesture (see
    // docs/remarkable-appload-platform-notes.md); `close`/`unloading` above stay
    // because the host still looks them up on the root.
    Rectangle {
        id: topBar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: theme.topBarHeight
        z: 1000
        color: theme.background

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 2
            color: theme.divider
        }

        // Filled dot = online, hollow ring = offline/connecting -- a solid-vs-open
        // shape reads at a glance on e-ink even where the text color barely shifts.
        Rectangle {
            id: statusDot
            anchors.left: parent.left
            anchors.leftMargin: theme.pageSideMargin
            anchors.verticalCenter: parent.verticalCenter
            width: theme.fontLabel * 0.48
            height: width
            radius: width / 2
            color: root.online ? theme.text : "transparent"
            border.width: root.online ? 0 : 2
            border.color: (root.connectivityKnown && !root.online)
                ? theme.errorText
                : theme.textMuted
        }

        Text {
            anchors.left: statusDot.right
            anchors.leftMargin: theme.spacingXs
            anchors.right: parent.right
            anchors.rightMargin: theme.pageSideMargin
            anchors.verticalCenter: parent.verticalCenter
            text: root.connectivityLabel()
            elide: Text.ElideRight
            font.pixelSize: theme.fontLabel
            font.bold: root.connectivityKnown && !root.online
            color: (!root.connectivityKnown || root.online)
                ? theme.textMuted
                : theme.errorText
        }

        EinkRefreshArea {
            anchors.fill: parent
            displayMethod: EinkRefreshArea.UI
        }
    }
}
