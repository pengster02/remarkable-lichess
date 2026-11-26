import QtQuick 2.5

Rectangle {
    id: homeScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: homeScreen.darkMode }
    ChessDisplay { id: chessDisplay }
    property var backendSender
    property var navigateTo
    property var nextRequestId
    property var openGame: function() {}
    property var respondToChallenge
    property bool darkMode: false
    property bool liveClockEnabled: true
    readonly property var navigationActions: [
        {name: "homeNewGame", label: "New game", screen: "SeekScreen.qml", primary: true},
        {name: "homeGameHistory", label: "Game history", screen: "GameHistoryScreen.qml", primary: false},
        {name: "homeSettings", label: "Settings", screen: "SettingsScreen.qml", primary: false}
    ]
    // Every now-playing game, not just one -- replaces the old singular
    // resumableGameId, which silently dropped every game past the first for
    // anyone with more than one correspondence game going (see protocol.rs's
    // HomeState/OngoingGameSummary).
    property var ongoingGames: []
    // Update deadlines separately from the rows. Recreating buttons interrupts
    // taps, while one timer per row wakes independently for the same snapshot.
    property var correspondenceSecondsLeft: ({})
    property double gamesReceivedAtMs: 0
    property double correspondenceNowMs: Date.now()
    readonly property double correspondenceAgeMs: Math.max(0, correspondenceNowMs - gamesReceivedAtMs)
    readonly property double nextCorrespondenceRefreshMs: {
        var next = Infinity
        for (var i = 0; i < homeScreen.ongoingGames.length; ++i) {
            var remaining = homeScreen.correspondenceTimeLeftMs(homeScreen.ongoingGames[i].game_id)
            if (remaining > 0) next = Math.min(next, chessDisplay.nextCorrespondenceTickMs(remaining))
        }
        return isFinite(next) ? Math.max(1, next - homeScreen.correspondenceAgeMs % 1000) : 0
    }
    // {speed, rating} pairs for whichever standard speed categories this
    // account has actually played at least one game of (see backend_app.rs's
    // ratings_from_perfs) -- shown so Home isn't just a blank slate between
    // games, matching every reference client's own home/profile screen.
    property var ratings: []
    property var pendingChallenges: []
    readonly property real offscreenChallengeY: {
        if (pendingChallenges.length === 0) return -1
        var top = homePager.contentY
        var bottom = top + homePager.visiblePageHeight
        var tolerance = homePager.positionTolerance
        for (var index = 0; index < challengesCard.content.length; ++index) {
            var row = challengesCard.content[index]
            if (!row.modelData || !row.visible || row.height <= 0) continue
            var y = challengesCard.y + challengesCard.contentTop + row.y
            if (y < top - tolerance || y + row.height > bottom + tolerance) return y
        }
        return -1
    }
    readonly property string challengeShortcutLabel: offscreenChallengeY < 0 ? ""
        : pendingChallenges.length === 1 ? "1 challenge" : pendingChallenges.length + " challenges"
    // Pushed down from main.qml's root state, same pattern as darkMode --
    // set once from TokenVerified's own username field, which used to be
    // parsed there and then never stored or shown anywhere in the UI at all.
    property string username: ""
    // First HomeState hasn't arrived yet -- without this, a fresh login shows a
    // fully empty Home (no ratings/games/challenges rendered, nothing telling
    // the user anything is even happening) indistinguishable from "you have
    // nothing going on", which isn't true, it just hasn't loaded yet.
    property bool loadedOnce: false
    property int homeRequestId: 0
    property int ratingsRequestId: 0
    property bool gamesLoadPending: false
    property bool gamesRefreshQueued: false
    readonly property bool canRefreshGames: !!homeScreen.backendSender && !!homeScreen.nextRequestId &&
        !homeScreen.gamesLoadPending && !homeScreen.gamesRefreshQueued && !gameRetryDelay.running
    // Hide finished IDs until a later read confirms removal. Waiting for GET
    // keeps a dead Resume button, and removing only the row lets GET restore it.
    property var finishedGameIds: []
    property bool connectivityKnown: false
    property bool online: false
    property var wifiConnected: null
    property string connectionMessage: ""
    property string loadError: ""
    property string challengesError: ""
    property string actionError: ""
    property var pendingInvitation: null
    readonly property string pendingChallengeId: pendingInvitation ? pendingInvitation.challengeId : ""
    readonly property string pendingChallengeAction: pendingInvitation ? pendingInvitation.action : ""

    onBackendSenderChanged: homeScreen.refresh()
    onNextRequestIdChanged: homeScreen.refresh()
    onVisibleChanged: if (homeScreen.visible) homeScreen.correspondenceNowMs = Date.now()
    onLiveClockEnabledChanged: if (homeScreen.liveClockEnabled) homeScreen.correspondenceNowMs = Date.now()

    // Coalesce events while a list is loading. Restarting every read can starve
    // the list, and a queue of every event repeats reads for the same snapshot.
    Timer {
        id: gameRefreshDelay
        interval: 250
        onTriggered: homeScreen.refreshGames(true)
    }
    Timer {
        id: gameRetryDelay
        onTriggered: homeScreen.queueGamesRefresh()
    }
    Timer {
        interval: Math.max(1, homeScreen.nextCorrespondenceRefreshMs)
        running: homeScreen.visible && homeScreen.liveClockEnabled && homeScreen.nextCorrespondenceRefreshMs > 0
        repeat: true
        onTriggered: homeScreen.correspondenceNowMs = Date.now()
    }

    function correspondenceTimeLeftMs(gameId) {
        var seconds = homeScreen.correspondenceSecondsLeft[gameId]
        if (typeof seconds !== "number") return null
        var elapsed = homeScreen.liveClockEnabled ? Math.floor(homeScreen.correspondenceAgeMs / 1000) * 1000 : 0
        return Math.max(0, seconds * 1000 - elapsed)
    }

    function acceptsHomeReply(msg) {
        var expected = msg.type === "HomeRatings" ? homeScreen.ratingsRequestId : homeScreen.homeRequestId
        return expected > 0 && msg.request_id === expected
    }

    function refresh() {
        homeScreen.challengesError = ""
        homeScreen.actionError = ""
        if (homeScreen.refreshGames()) homeScreen.backendSender({type: "RequestChallenges"})
    }

    function refreshGames(gamesOnly) {
        if (!homeScreen.backendSender || !homeScreen.nextRequestId) return false
        gameRefreshDelay.stop()
        homeScreen.gamesRefreshQueued = false
        homeScreen.gamesLoadPending = true
        homeScreen.homeRequestId = homeScreen.nextRequestId()
        var request = {type: "RequestHome", request_id: homeScreen.homeRequestId}
        if (gamesOnly) {
            request.games_only = true
        } else {
            homeScreen.loadedOnce = false
            homeScreen.connectivityKnown = false
            homeScreen.loadError = ""
            homeScreen.ratingsRequestId = homeScreen.homeRequestId
        }
        homeScreen.backendSender(request)
        return true
    }

    function queueGamesRefresh() {
        homeScreen.gamesRefreshQueued = true
        if (!homeScreen.gamesLoadPending && !gameRetryDelay.running) gameRefreshDelay.start()
    }

    function refreshChallenges() {
        homeScreen.challengesError = ""
        homeScreen.backendSender({type: "RequestChallenges"})
    }

    function submitChallengeAction(action, challengeId) {
        if (homeScreen.pendingInvitation || !homeScreen.respondToChallenge) return
        homeScreen.actionError = ""
        homeScreen.respondToChallenge(action, challengeId)
    }

    function showOffscreenChallenge() {
        if (homeScreen.offscreenChallengeY >= 0) homePager.moveTo(homeScreen.offscreenChallengeY)
    }

    function invitationTimeText(challenge) {
        var kind = challenge.time_control
        if (kind === "unlimited") return "Untimed"
        if (kind === "correspondence") {
            var days = challenge.days_per_turn
            if (typeof days !== "number" || days <= 0) return "Correspondence"
            return days === 1 ? "1 day per move" : days + " days per move"
        }
        if (kind !== "clock" && kind !== undefined && kind !== null) return "Time control unavailable"

        var limit = challenge.limit_seconds
        var increment = challenge.increment_seconds
        if (typeof limit !== "number" || limit < 0 || typeof increment !== "number" || increment < 0) {
            return kind === "clock" ? "Real-time" : "Time control unavailable"
        }
        var minutes = Math.floor(limit / 60)
        var seconds = limit % 60
        if (seconds === 0) return minutes + "+" + increment
        return (minutes > 0 ? minutes + "m " : "") + seconds + "s + " + increment + "s"
    }

    function invitationDetails(challenge) {
        var details = [homeScreen.invitationTimeText(challenge)]
        if (typeof challenge.rated === "boolean") details.push(challenge.rated ? "Rated" : "Casual")
        if (challenge.variant) details.push(chessDisplay.variantLabel(challenge.variant) || "Standard")
        return details.join(" · ")
    }

    function connectivityLabel() {
        if (!homeScreen.connectivityKnown) return "Checking connection..."
        if (homeScreen.online) return "Online"
        if (homeScreen.wifiConnected === false) return "Offline — Wi-Fi disconnected"
        return "Offline — Lichess unreachable"
    }

    function pageRows() {
        var rows = []
        for (var index = 0; index < contentColumn.children.length; ++index) {
            var item = contentColumn.children[index]
            if (!item.visible) continue
            if (item !== challengesCard && item !== gamesCard) {
                rows.push(item)
                continue
            }

            // Keep the heading with the first row and include the card padding
            // on the last row. Whole-card or fixed-count paging splits long lists.
            var first = rows.length
            var top = item.y
            for (var childIndex = 0; childIndex < item.content.length; ++childIndex) {
                var child = item.content[childIndex]
                if (!child.visible || child.height <= 0) continue
                var childTop = item.y + item.contentTop + child.y
                if (rows.length > first) top = childTop
                rows.push({y: top, height: childTop + child.height - top, visible: true})
            }
            if (rows.length > first) {
                var last = rows[rows.length - 1]
                last.height = item.y + item.height - last.y
            }
        }
        return rows
    }

    // Keep destinations reachable from every page. A first-page menu requires
    // paging back, and a separate menu adds a tap to every visit.
    Row {
        id: homeNavigation
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: theme.pageTopMargin
        anchors.leftMargin: theme.pageSideMargin
        anchors.rightMargin: theme.pageSideMargin
        spacing: theme.spacingXs

        Repeater {
            model: homeScreen.navigationActions
            AppButton {
                required property var modelData
                objectName: modelData.name
                width: (homeNavigation.width - homeNavigation.spacing * (homeScreen.navigationActions.length - 1))
                    / homeScreen.navigationActions.length
                compact: true
                leftPadding: theme.spacingXs
                rightPadding: theme.spacingXs
                text: modelData.label
                highlighted: modelData.primary
                enabled: !!homeScreen.navigateTo
                onClicked: homeScreen.navigateTo(modelData.screen)
            }
        }
    }

    EinkPagedFlickable {
        id: homePager
        objectName: "homePager"
        anchors.top: homeNavigation.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.topMargin: theme.spacingSmall
        anchors.leftMargin: theme.pageSideMargin
        anchors.rightMargin: theme.pageSideMargin
        anchors.bottomMargin: theme.pageSideMargin
        contentHeight: contentColumn.height
        keepRowsTogether: true
        pageStops: rowPageStops(homeScreen.pageRows())

        Column {
            id: contentColumn
            width: parent.width
            spacing: theme.spacingMedium

            AppPageHeader {
                width: parent.width
                darkMode: homeScreen.darkMode
                eyebrow: "Your board"
                title: "Lichess"
                detail: homeScreen.username
                pieceSource: "../assets/pieces/cburnett/wN.png"
            }

            Text {
                visible: !homeScreen.loadedOnce
                text: "Loading your games..."
                font.pixelSize: theme.fontLabel
                font.italic: true
                color: theme.textMuted
            }

            SectionCard {
                darkMode: homeScreen.darkMode
                title: "Challenges unavailable"
                visible: homeScreen.challengesError.length > 0

                Text {
                    width: parent.width
                    text: homeScreen.challengesError
                    wrapMode: Text.WordWrap
                    font.pixelSize: theme.fontBody
                    color: theme.errorText
                }
                AppButton {
                    width: parent.width
                    text: "Retry challenges"
                    onClicked: homeScreen.refreshChallenges()
                }
            }

            SectionCard {
                objectName: "homeActionErrorCard"
                darkMode: homeScreen.darkMode
                title: "Action not completed"
                visible: homeScreen.actionError.length > 0

                Text {
                    width: parent.width
                    text: homeScreen.actionError
                    wrapMode: Text.WordWrap
                    font.pixelSize: theme.fontBody
                    color: theme.errorText
                }
                AppButton {
                    width: parent.width
                    compact: true
                    text: "Dismiss"
                    onClicked: homeScreen.actionError = ""
                }
            }

            // Show invitations before the long game list so their actions are reachable
            // immediately. A banner or a separate screen would add another step.
            SectionCard {
                id: challengesCard
                darkMode: homeScreen.darkMode
                title: "Challenges"
                visible: homeScreen.pendingChallenges.length > 0 || homeScreen.pendingInvitation !== null
                Text {
                    objectName: "pendingInvitationStatus"
                    width: parent.width
                    visible: homeScreen.pendingInvitation !== null &&
                        !homeScreen.pendingChallenges.some(function(challenge) {
                            return challenge.id === homeScreen.pendingChallengeId
                        })
                    text: homeScreen.pendingChallengeAction === "accept"
                        ? "Accepting challenge…" : "Declining challenge…"
                    wrapMode: Text.WordWrap
                    font.pixelSize: theme.fontBody
                    color: theme.textMuted
                }
                Repeater {
                    model: homeScreen.pendingChallenges
                    // Stacked (text above buttons) rather than one Row -- a long
                    // challenger name plus two buttons doesn't reliably fit the
                    // device's ~400px content width, and a fixed-width Column
                    // won't wrap an overflowing Row, it'll just clip.
                    Column {
                        id: invitationRow
                        required property var modelData
                        readonly property bool canAccept: modelData.board_supported !== false
                        width: parent.width
                        spacing: theme.spacingXs

                        Text {
                            text: modelData.challenger + " challenges you (" + homeScreen.invitationDetails(modelData) + ")"
                            font.pixelSize: theme.fontLabel
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            width: parent.width
                            color: theme.text
                        }
                        Text {
                            objectName: "homeUnsupportedChallenge"
                            visible: !invitationRow.canAccept
                            text: modelData.board_unavailable_reason || "This variant cannot be played on the tablet."
                            textFormat: Text.PlainText
                            width: parent.width
                            wrapMode: Text.WordWrap
                            font.pixelSize: theme.fontSmall
                            color: theme.textMuted
                        }
                        Row {
                            width: parent.width
                            spacing: theme.spacingSmall
                            // Two half-width targets filling the row -- Accept
                            // gets the accent treatment as the primary action.
                            AppButton {
                                objectName: "homeAcceptChallenge"
                                width: (parent.width - theme.spacingSmall) / 2
                                text: homeScreen.pendingChallengeId === modelData.id &&
                                    homeScreen.pendingChallengeAction === "accept"
                                    ? "Accepting…"
                                    : "Accept"
                                highlighted: true
                                enabled: invitationRow.canAccept && homeScreen.pendingChallengeId.length === 0
                                onClicked: homeScreen.submitChallengeAction("accept", modelData.id)
                            }
                            AppButton {
                                objectName: "homeDeclineChallenge"
                                width: (parent.width - theme.spacingSmall) / 2
                                text: homeScreen.pendingChallengeId === modelData.id &&
                                    homeScreen.pendingChallengeAction === "decline"
                                    ? "Declining…"
                                    : "Decline"
                                enabled: homeScreen.pendingChallengeId.length === 0
                                onClicked: homeScreen.submitChallengeAction("decline", modelData.id)
                            }
                        }
                    }
                }
            }

            SectionCard {
                id: gamesCard
                darkMode: homeScreen.darkMode
                title: "Your games"
                visible: homeScreen.loadedOnce || homeScreen.ongoingGames.length > 0
                Text {
                    width: parent.width
                    visible: homeScreen.loadError.length > 0
                    text: homeScreen.loadError
                    wrapMode: Text.WordWrap
                    font.pixelSize: theme.fontBody
                    color: theme.errorText
                }
                Text {
                    visible: homeScreen.loadedOnce && !homeScreen.loadError && homeScreen.ongoingGames.length === 0
                    text: "No games in progress"
                    font.pixelSize: theme.fontLabel
                    color: theme.textMuted
                }
                Row {
                    width: parent.width
                    spacing: theme.spacingSmall

                    // Account events omit moves. Polling adds recurring HTTP reads and per-game
                    // streams keep sockets open, so refresh the visible list on demand.
                    AppButton {
                        objectName: "homeGamesRefreshButton"
                        width: (parent.width - parent.spacing) / 2
                        compact: true
                        text: homeScreen.gamesLoadPending ? "Refreshing games…" :
                            homeScreen.loadError ? "Retry games" : "Refresh games"
                        enabled: homeScreen.canRefreshGames
                        onClicked: homeScreen.queueGamesRefresh()
                    }
                    AppButton {
                        objectName: "homeRefreshButton"
                        width: (parent.width - parent.spacing) / 2
                        compact: true
                        text: "Refresh all"
                        enabled: homeScreen.canRefreshGames
                        onClicked: homeScreen.refresh()
                    }
                }
                Repeater {
                    model: homeScreen.ongoingGames
                    Column {
                        id: gameRow
                        required property var modelData
                        readonly property bool canResume: modelData.board_supported !== false
                        readonly property string variantLabel: chessDisplay.variantLabel(modelData.variant)
                        readonly property var correspondenceMs: homeScreen.correspondenceTimeLeftMs(modelData.game_id)
                        width: parent.width
                        spacing: theme.spacingXs

                        Text {
                            objectName: "homeGameSummary"
                            text: (modelData.opponent_name || "Opponent") +
                                  (modelData.opponent_rating ? " (" + modelData.opponent_rating + ")" : "") +
                                  (modelData.is_my_turn ? " — your move" : " — waiting") +
                                  (gameRow.variantLabel ? " · " + gameRow.variantLabel : "") +
                                  (gameRow.correspondenceMs === null ? "" :
                                      " ·\u00a0" + chessDisplay.formatCorrespondenceClock(gameRow.correspondenceMs)
                                          .replace(/ /g, "\u00a0") + "\u00a0left")
                            font.pixelSize: theme.fontLabel
                            font.bold: modelData.is_my_turn
                            wrapMode: Text.WordWrap
                            textFormat: Text.PlainText
                            width: parent.width
                            color: theme.text
                        }
                        // Keep the turn and deadline visible. Dropping the row loses them,
                        // and a disabled Resume alone would leave its cause unclear.
                        Text {
                            objectName: "homeUnsupportedGame"
                            visible: !gameRow.canResume
                            text: "This variant is unavailable on the tablet."
                            width: parent.width
                            wrapMode: Text.WordWrap
                            font.pixelSize: theme.fontSmall
                            color: theme.textMuted
                        }
                        AppButton {
                            objectName: "homeResumeButton"
                            // Full-width row, not a shrink-wrapped button --
                            // the e-ink list convention (KOReader et al.):
                            // a row's hittability comes from spanning the
                            // whole content width.
                            width: parent.width
                            visible: gameRow.canResume
                            text: "Resume"
                            highlighted: modelData.is_my_turn
                            onClicked: homeScreen.openGame(modelData.game_id)
                        }
                    }
                }
            }

            SectionCard {
                darkMode: homeScreen.darkMode
                title: "Your ratings"
                visible: homeScreen.ratings.length > 0
                Flow {
                    width: parent.width
                    spacing: theme.spacingSmall
                    Repeater {
                        model: homeScreen.ratings
                        Text {
                            required property var modelData
                            text: chessDisplay.speedLabel(modelData.speed) + "  <b>" + modelData.rating + "</b>"
                            textFormat: Text.StyledText
                            font.pixelSize: theme.fontBody
                            color: theme.text
                        }
                    }
                }
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "HomeState") {
            if (!homeScreen.acceptsHomeReply(msg)) return
            homeScreen.gamesLoadPending = false
            homeScreen.loadedOnce = true
            homeScreen.loadError = ""
            gameRetryDelay.stop()
            var games = msg.ongoing_games || []
            var next = games.filter(function(game) {
                return homeScreen.finishedGameIds.indexOf(game.game_id) === -1
            })
            var secondsLeft = {}
            for (var i = 0; i < next.length; ++i) {
                var game = next[i]
                if (game.is_my_turn && typeof game.correspondence_seconds_left === "number") {
                    secondsLeft[game.game_id] = game.correspondence_seconds_left
                }
            }
            homeScreen.gamesReceivedAtMs = Date.now()
            homeScreen.correspondenceNowMs = homeScreen.gamesReceivedAtMs
            homeScreen.correspondenceSecondsLeft = secondsLeft
            var shown = homeScreen.ongoingGames
            // An equal snapshot should keep the Resume delegates and their input state.
            if (next.length !== shown.length || next.some(function(game, index) {
                var old = shown[index]
                return game.game_id !== old.game_id || game.opponent_name !== old.opponent_name ||
                    game.opponent_rating !== old.opponent_rating || game.is_my_turn !== old.is_my_turn ||
                    game.variant !== old.variant || game.board_supported !== old.board_supported
            })) homeScreen.ongoingGames = next
            if (homeScreen.gamesRefreshQueued) {
                homeScreen.queueGamesRefresh()
            } else {
                var listedIds = games.map(function(game) { return game.game_id })
                homeScreen.finishedGameIds = homeScreen.finishedGameIds.filter(function(id) {
                    return listedIds.indexOf(id) !== -1
                })
            }
        } else if (msg.type === "HomeRatings") {
            if (!homeScreen.acceptsHomeReply(msg)) return
            homeScreen.ratings = msg.ratings || []
        } else if (msg.type === "GameStarted") {
            var alreadyListed = homeScreen.ongoingGames.some(function(game) { return game.game_id === msg.game_id })
            if (!alreadyListed && homeScreen.finishedGameIds.indexOf(msg.game_id) === -1) {
                homeScreen.queueGamesRefresh()
            }
        } else if (msg.type === "GameFinished") {
            if (homeScreen.finishedGameIds.indexOf(msg.game_id) !== -1) return
            var remaining = homeScreen.ongoingGames.filter(function(game) { return game.game_id !== msg.game_id })
            var removed = remaining.length !== homeScreen.ongoingGames.length
            if (!removed && !homeScreen.gamesLoadPending && !homeScreen.gamesRefreshQueued) return
            homeScreen.finishedGameIds = homeScreen.finishedGameIds.concat([msg.game_id])
            if (removed) homeScreen.ongoingGames = remaining
            homeScreen.queueGamesRefresh()
        } else if (msg.type === "AccountEventsResumed") {
            homeScreen.queueGamesRefresh()
        } else if (msg.type === "PendingChallenges") {
            homeScreen.challengesError = ""
            homeScreen.pendingChallenges = msg.challenges || []
        } else if (msg.type === "ChallengeAccepted" || msg.type === "ChallengeDeclined") {
            var id = msg.game_id || msg.challenge_id
            homeScreen.pendingChallenges = homeScreen.pendingChallenges.filter(function(challenge) {
                return challenge.id !== id
            })
        } else if (msg.type === "ChallengeActionFailed") {
            homeScreen.actionError = msg.message || "Lichess could not complete that action."
        } else if (msg.type === "ConnectivityState") {
            homeScreen.connectivityKnown = true
            homeScreen.online = msg.online || false
            homeScreen.wifiConnected = msg.wifi_connected !== undefined
                ? msg.wifi_connected
                : null
            homeScreen.connectionMessage = msg.message || ""
        } else if (msg.type === "HomeLoadFailed") {
            if (!homeScreen.acceptsHomeReply(msg)) return
            homeScreen.gamesLoadPending = false
            homeScreen.loadedOnce = true
            homeScreen.loadError = msg.message ||
                "Couldn't load your games. Check Wi-Fi and retry."
            if (msg.retry_after_ms > 0) {
                gameRetryDelay.interval = msg.retry_after_ms
                gameRetryDelay.restart()
                homeScreen.gamesRefreshQueued = true
            } else if (homeScreen.gamesRefreshQueued) {
                homeScreen.queueGamesRefresh()
            }
        } else if (msg.type === "ChallengesLoadFailed") {
            homeScreen.challengesError = msg.message ||
                "Couldn't load challenges."
        } else if (msg.type === "ErrorMsg") {
            homeScreen.actionError = msg.message || "Lichess could not complete that action."
        }
    }
}
