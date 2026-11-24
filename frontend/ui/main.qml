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
    // Explicitly models startup so LoginScreen never flashes while a saved token
    // is being verified. Alternatives: a timer-delayed login, or a blank Loader.
    property string authenticationState: "checking"
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
    property int reviewRequestId: 0
    // A shared sequence survives screen changes. Per-screen counters can repeat
    // IDs after navigation, and timestamps can collide across rapid requests.
    property int requestSequence: 0
    property var pendingReview: null

    // Connectivity lives at the root (not per-screen) so the persistent top bar
    // can show it on every screen -- fed by the backend's ConnectivityState (see
    // the message router below and backend_app.rs's wifi_link_state).
    property bool connectivityKnown: false
    property bool online: false
    property var wifiConnected: null
    property string connectionMessage: ""
    // Bind replies to the selected board even while it loads. Trusting the next
    // snapshot or waiting to set the ID until the first frame both allow a stale board.
    property string selectedGameId: ""
    // Keep resolved IDs across navigation until a newer list omits them. Waiting
    // for the list keeps old rows visible, while removing a row only on its page
    // lets an in-flight list restore it.
    property var resolvedChallengeIds: []
    // A remounted Home still needs the pending response. Page-local state permits
    // another POST, while always opening on acceptance can replace a later screen.
    property var pendingInvitation: null

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
        if (game && game.review_supported === false) return
        if (root.pendingReview && root.pendingReview.gameId === gameId) return
        root.pendingReview = {id: root.nextRequestId(), gameId: gameId, game: game || null}
        root.sendToBackend({type: "RequestGameMoves", game_id: gameId,
                            request_id: root.pendingReview.id})
    }

    function returnToGameHistory(visit) {
        if (root.hasToken) screenLoader.setSource("GameHistoryScreen.qml", visit || {})
    }

    function nextRequestId() {
        root.requestSequence += 1
        return root.requestSequence
    }

    function respondToChallenge(action, challengeId) {
        if (!root.hasToken || root.pendingInvitation || !challengeId) return
        var requestId = root.nextRequestId()
        root.pendingInvitation = {action: action, challengeId: challengeId,
                                  requestId: requestId, openOnSuccess: true}
        root.sendToBackend({type: action === "accept" ? "AcceptChallenge" : "DeclineChallenge",
                            id: challengeId, request_id: requestId})
    }

    function handleChallengeResponse(msg) {
        var request = root.pendingInvitation
        var accepted = msg.type === "ChallengeAccepted"
        var succeeded = accepted || msg.type === "ChallengeDeclined"
        var id = accepted ? msg.game_id : msg.challenge_id
        if (!root.hasToken || !request || request.challengeId !== id ||
                request.requestId !== msg.request_id ||
                (succeeded && accepted !== (request.action === "accept"))) return

        root.pendingInvitation = null
        if (succeeded && root.resolvedChallengeIds.indexOf(id) === -1) {
            root.resolvedChallengeIds = root.resolvedChallengeIds.concat([id])
        }
        var home = screenLoader.item
        if (!home || !home.acceptsHomeReply) return
        home.handleMessage(msg)
        if (accepted) {
            if (request.openOnSuccess) root.openGame(id)
            else home.queueGamesRefresh()
        }
    }

    function cancelPendingReview() {
        var request = root.pendingReview
        if (!request) return
        root.pendingReview = null
        root.sendToBackend({type: "CancelGameReview", request_id: request.id})
    }

    function applyConnectivity(msg) {
        root.connectivityKnown = true
        root.online = msg.online || false
        root.wifiConnected = msg.wifi_connected !== undefined ? msg.wifi_connected : null
        root.connectionMessage = msg.message || ""
        if (screenLoader.item && screenLoader.item.handleMessage) {
            screenLoader.item.handleMessage(msg)
        }
    }

    function openGame(gameId) {
        if (!root.hasToken || !gameId) return
        screenLoader.source = "BoardScreen.qml"
        root.selectedGameId = gameId
        root.sendToBackend({type: "ResumeGame", game_id: gameId})
    }

    function requireAuthentication() {
        root.hasToken = false
        root.authenticationState = "required"
        root.username = ""
        root.selectedGameId = ""
        root.resolvedChallengeIds = []
        root.pendingInvitation = null
        root.pendingReview = null
        root.reviewGame = null
        root.reviewRequestId = 0
        root.reviewMoves = []
        root.reviewFens = []
        root.reviewClockMs = []
        root.reviewAnalysis = []
        screenLoader.source = "LoginScreen.qml"
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
                var login = screenLoader.item
                if (typeof msg.request_id === "number" &&
                        (!login || !login.acceptsCommittedSignIn || !login.acceptsCommittedSignIn(msg))) return
                if (root.username !== (msg.username || "")) {
                    root.resolvedChallengeIds = []
                    root.pendingInvitation = null
                }
                root.hasToken = true
                root.authenticationState = "authenticated"
                root.username = msg.username || ""
                endpoint.sendMessage(1, JSON.stringify({type: "RequestSettings"}))
                screenLoader.source = "HomeScreen.qml"
            } else if (msg.type === "AuthenticationRequired") {
                root.requireAuthentication()
            } else if (msg.type === "AuthenticationCheckFailed") {
                if (root.authenticationState === "checking" && screenLoader.item) {
                    screenLoader.item.handleMessage(msg)
                }
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
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "TokenInvalid") {
                root.requireAuthentication()
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "LoginChallenge" || msg.type === "LoginVerifying" ||
                       msg.type === "SignInReady" || msg.type === "LoginFailed") {
                if (root.authenticationState === "required" && screenLoader.item &&
                        screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "ConnectivityState") {
                root.applyConnectivity(msg)
            } else if (msg.type === "HomeState" || msg.type === "HomeLoadFailed" ||
                       msg.type === "HomeRatings") {
                var home = screenLoader.item
                if (!root.hasToken || !home || !home.acceptsHomeReply || !home.acceptsHomeReply(msg)) return
                if (msg.type !== "HomeRatings" && !msg.retry_after_ms) {
                    root.applyConnectivity({type: "ConnectivityState", online: msg.type === "HomeState",
                                            wifi_connected: msg.wifi_connected, message: msg.message})
                }
                home.handleMessage(msg)
            } else if (msg.type === "ChallengeAccepted" || msg.type === "ChallengeDeclined" ||
                       msg.type === "ChallengeActionFailed") {
                root.handleChallengeResponse(msg)
            } else if (msg.type === "GameFinished" || msg.type === "AccountEventsResumed") {
                var homeForEvent = screenLoader.item
                if (root.hasToken && homeForEvent && homeForEvent.acceptsHomeReply) {
                    homeForEvent.handleMessage(msg)
                }
            } else if (msg.type === "SeekCreated" || msg.type === "SeekFailed" ||
                       msg.type === "SeekEnded" || msg.type === "ChallengeCreated" ||
                       msg.type === "ChallengeCreateFailed" ||
                       msg.type === "GameStarted" || msg.type === "ComputerGameCreated" ||
                       msg.type === "MatchCreationFailed" ||
                       msg.type === "ChallengeResolved" ||
                       msg.type === "OpenChallengeCreated" ||
                       msg.type === "PendingChallenges" ||
                       msg.type === "ChallengesLoadFailed" ||
                       msg.type === "GameHistory" || msg.type === "GameHistoryFailed") {
                if (msg.type === "GameStarted" && !root.hasToken) return
                if (root.hasToken && msg.type === "PendingChallenges" && root.resolvedChallengeIds.length > 0) {
                    var pending = msg.challenges || []
                    var ids = pending.map(function(challenge) { return challenge.id })
                    root.resolvedChallengeIds = root.resolvedChallengeIds.filter(function(id) {
                        return ids.indexOf(id) !== -1
                    })
                    msg.challenges = pending.filter(function(challenge) {
                        return root.resolvedChallengeIds.indexOf(challenge.id) === -1
                    })
                }
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "GameMoves" || msg.type === "GameMovesFailed") {
                var request = root.pendingReview
                if (!request || msg.request_id !== request.id) return
                root.pendingReview = null
                if (msg.type === "GameMovesFailed") {
                    screenLoader.item.handleMessage(msg)
                } else {
                    root.reviewGame = request.game && typeof msg.rating_diff === "number"
                        ? Object.assign({}, request.game, {rating_diff: msg.rating_diff})
                        : request.game
                    root.reviewRequestId = request.id
                    root.reviewMoves = msg.moves || []
                    root.reviewFens = msg.fens || []
                    root.reviewClockMs = msg.clock_ms || []
                    root.reviewAnalysis = msg.analysis || []
                    var sourceScreen = screenLoader.item
                    var visit = sourceScreen && sourceScreen.captureHistoryVisit
                        ? sourceScreen.captureHistoryVisit() : null
                    // Scope the return data to this replay. A root cache can reach
                    // later visits, while saved settings would outlive sign-out.
                    screenLoader.setSource("GameReviewScreen.qml", {
                        returnToGameHistory: function() { root.returnToGameHistory(visit) }
                    })
                }
            } else if (msg.type === "AnalysisPosition" || msg.type === "AnalysisMove" || msg.type === "AnalysisFailed" ||
                       msg.type === "CloudEvaluation" ||
                       msg.type === "CloudEvaluationUnavailable" ||
                       msg.type === "CloudEvaluationFailed") {
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "BoardState" || msg.type === "PlayerStatuses" ||
                       msg.type === "GameActionCompleted" || msg.type === "GameActionFailed") {
                if (!root.hasToken || !root.selectedGameId || msg.game_id !== root.selectedGameId) return
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "RatingDiff") {
                if (!root.hasToken || typeof msg.rating_diff !== "number") return
                var pending = root.pendingReview
                if (pending && pending.game && pending.gameId === msg.game_id) {
                    pending.game = Object.assign({}, pending.game, {rating_diff: msg.rating_diff})
                }
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "LogoutFailed" ||
                       msg.type === "GameOver" || msg.type === "MoveRejected" ||
                       msg.type === "GameStreamReconnecting" || msg.type === "GameStreamFailed" ||
                       msg.type === "OpponentGone" || msg.type === "MovePreview") {
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
        objectName: "screenLoader"
        // Sits below the persistent top bar so no screen underlaps it.
        anchors.top: topBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        source: "StartupScreen.qml"
        onSourceChanged: {
            root.cancelPendingReview()
            root.selectedGameId = ""
            if (root.pendingInvitation && root.pendingInvitation.openOnSuccess) {
                root.pendingInvitation = Object.assign({}, root.pendingInvitation, {openOnSuccess: false})
            }
        }
        onLoaded: {
            if (item.hasOwnProperty("backendSender")) {
                item.backendSender = root.sendToBackend
            }
            if (item.hasOwnProperty("showSignIn")) {
                item.showSignIn = root.requireAuthentication
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
            if (item.hasOwnProperty("reviewRequestId")) {
                item.reviewRequestId = root.reviewRequestId
            }
            if (item.hasOwnProperty("selectGameForReview")) {
                item.selectGameForReview = root.selectGameForReview
            }
            if (item.hasOwnProperty("openGameReview")) {
                item.openGameReview = root.openGameReview
            }
            if (item.hasOwnProperty("nextRequestId")) {
                item.nextRequestId = root.nextRequestId
            }
            if (item.hasOwnProperty("openingReview")) {
                item.openingReview = Qt.binding(function() { return root.pendingReview !== null })
            }
            if (item.hasOwnProperty("openGame")) {
                item.openGame = root.openGame
            }
            if (item.hasOwnProperty("respondToChallenge")) {
                item.respondToChallenge = root.respondToChallenge
                item.pendingInvitation = Qt.binding(function() { return root.pendingInvitation })
            }
            if (item.hasOwnProperty("requestedGameId")) {
                item.requestedGameId = Qt.binding(function() { return root.selectedGameId })
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
        objectName: "connectivityBar"
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        // Startup supplies its own feedback. A placeholder repeats it and an
        // empty bar would leave a gap until connectivity is known.
        visible: root.connectivityKnown || root.authenticationState !== "checking"
        height: visible ? theme.topBarHeight : 0
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
