import QtQuick 2.5

Rectangle {
    id: homeScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: homeScreen.darkMode }
    ChessDisplay { id: chessDisplay }
    property var backendSender
    property var navigateTo
    property var expectNextGame: function() {}
    property bool darkMode: false
    // Every now-playing game, not just one -- replaces the old singular
    // resumableGameId, which silently dropped every game past the first for
    // anyone with more than one correspondence game going (see protocol.rs's
    // HomeState/OngoingGameSummary).
    property var ongoingGames: []
    // {speed, rating} pairs for whichever standard speed categories this
    // account has actually played at least one game of (see backend_app.rs's
    // ratings_from_perfs) -- shown so Home isn't just a blank slate between
    // games, matching every reference client's own home/profile screen.
    property var ratings: []
    property var pendingChallenges: []
    // Pushed down from main.qml's root state, same pattern as darkMode --
    // set once from TokenVerified's own username field, which used to be
    // parsed there and then never stored or shown anywhere in the UI at all.
    property string username: ""
    // First HomeState hasn't arrived yet -- without this, a fresh login shows a
    // fully empty Home (no ratings/games/challenges rendered, nothing telling
    // the user anything is even happening) indistinguishable from "you have
    // nothing going on", which isn't true, it just hasn't loaded yet.
    property bool loadedOnce: false
    property bool connectivityKnown: false
    property bool online: false
    property var wifiConnected: null
    property string connectionMessage: ""
    property string loadError: ""
    property string challengesError: ""
    property string actionError: ""
    property string pendingChallengeId: ""
    property string pendingChallengeAction: ""

    onBackendSenderChanged: {
        if (homeScreen.backendSender) homeScreen.refresh()
    }

    function refresh() {
        homeScreen.loadedOnce = false
        homeScreen.connectivityKnown = false
        homeScreen.loadError = ""
        homeScreen.challengesError = ""
        homeScreen.actionError = ""
        homeScreen.backendSender({type: "RequestHome"})
        homeScreen.backendSender({type: "RequestChallenges"})
    }

    function refreshChallenges() {
        homeScreen.challengesError = ""
        homeScreen.backendSender({type: "RequestChallenges"})
    }

    function submitChallengeAction(action, challengeId) {
        if (homeScreen.pendingChallengeId.length > 0) return
        homeScreen.actionError = ""
        homeScreen.pendingChallengeId = challengeId
        homeScreen.pendingChallengeAction = action
        if (action === "accept") homeScreen.expectNextGame(challengeId)
        homeScreen.backendSender({
            type: action === "accept" ? "AcceptChallenge" : "DeclineChallenge",
            id: challengeId
        })
    }

    function connectivityLabel() {
        if (!homeScreen.connectivityKnown) return "Checking connection..."
        if (homeScreen.online) return "Online"
        if (homeScreen.wifiConnected === false) return "Offline — Wi-Fi disconnected"
        return "Offline — Lichess unreachable"
    }

    EinkPagedFlickable {
        anchors.fill: parent
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        contentHeight: contentColumn.height
        // No rubber-band overshoot at the ends -- same reasoning as every
        // other Flickable/ListView in this app (see GameHistoryScreen's own
        // comment on this): that bounce is itself a multi-frame animation,
        // a real e-ink refresh cost for a purely cosmetic effect. This one
        // was missing it before this pass -- the one Flickable in the app
        // that had drifted from that rule.

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
                title: "Connection problem"
                visible: homeScreen.loadError.length > 0

                Text {
                    width: parent.width
                    text: homeScreen.loadError
                    wrapMode: Text.WordWrap
                    font.pixelSize: theme.fontBody
                    color: theme.errorText
                }
                AppButton {
                    width: parent.width
                    text: "Retry"
                    highlighted: true
                    onClicked: homeScreen.refresh()
                }
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
                            // Rating number bold and a size class up from its
                            // label -- the number is what someone actually
                            // opens Home to check.
                            text: chessDisplay.speedLabel(modelData.speed) + "  <b>" + modelData.rating + "</b>"
                            textFormat: Text.StyledText
                            font.pixelSize: theme.fontBody
                            color: theme.text
                        }
                    }
                }
            }

            SectionCard {
                darkMode: homeScreen.darkMode
                title: "Your games"
                visible: homeScreen.ongoingGames.length > 0
                Repeater {
                    model: homeScreen.ongoingGames
                    // Same stacked-not-Row reasoning as pendingChallenges below --
                    // a long opponent name plus a Resume button doesn't reliably
                    // fit the device's ~400px content width.
                    Column {
                        required property var modelData
                        width: parent.width
                        spacing: theme.spacingXs

                        Text {
                            text: (modelData.opponent_name || "Opponent") +
                                  (modelData.opponent_rating ? " (" + modelData.opponent_rating + ")" : "") +
                                  (modelData.is_my_turn ? " — your move" : " — waiting")
                            font.pixelSize: theme.fontLabel
                            font.bold: modelData.is_my_turn
                            wrapMode: Text.WordWrap
                            width: parent.width
                            color: theme.text
                        }
                        AppButton {
                            // Full-width row, not a shrink-wrapped button --
                            // the e-ink list convention (KOReader et al.):
                            // a row's hittability comes from spanning the
                            // whole content width.
                            width: parent.width
                            text: "Resume"
                            highlighted: modelData.is_my_turn
                            onClicked: {
                                // No BoardState flows for an already-in-progress game
                                // until its stream is (re)attached server-side -- see
                                // ResumeGame's own comment in protocol.rs. We still
                                // navigate immediately after for a responsive UI
                                // instead of waiting on the first BoardState.
                                homeScreen.backendSender({type: "ResumeGame", game_id: modelData.game_id})
                                homeScreen.navigateTo("BoardScreen.qml")
                            }
                        }
                    }
                }
            }

            SectionCard {
                darkMode: homeScreen.darkMode
                title: "Challenges"
                visible: homeScreen.pendingChallenges.length > 0
                Repeater {
                    model: homeScreen.pendingChallenges
                    // Stacked (text above buttons) rather than one Row -- a long
                    // challenger name plus two buttons doesn't reliably fit the
                    // device's ~400px content width, and a fixed-width Column
                    // won't wrap an overflowing Row, it'll just clip.
                    Column {
                        required property var modelData
                        width: parent.width
                        spacing: theme.spacingXs

                        Text {
                            text: modelData.challenger + " challenges you (" + Math.floor((modelData.limit_seconds || 0) / 60) + "+" + (modelData.increment_seconds || 0) + ")"
                            font.pixelSize: theme.fontLabel
                            wrapMode: Text.WordWrap
                            width: parent.width
                            color: theme.text
                        }
                        Row {
                            width: parent.width
                            spacing: theme.spacingSmall
                            // Two half-width targets filling the row -- Accept
                            // gets the accent treatment as the primary action.
                            AppButton {
                                width: (parent.width - theme.spacingSmall) / 2
                                text: homeScreen.pendingChallengeId === modelData.id &&
                                    homeScreen.pendingChallengeAction === "accept"
                                    ? "Accepting…"
                                    : "Accept"
                                highlighted: true
                                enabled: homeScreen.pendingChallengeId.length === 0
                                onClicked: homeScreen.submitChallengeAction("accept", modelData.id)
                            }
                            AppButton {
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

            Column {
                width: parent.width
                spacing: theme.spacingSmall

                MenuRow {
                    width: parent.width
                    darkMode: homeScreen.darkMode
                    title: "New game"
                    subtitle: "Find a match or challenge a player"
                    highlighted: true
                    onClicked: homeScreen.navigateTo("SeekScreen.qml")
                }

                MenuRow {
                    width: parent.width
                    darkMode: homeScreen.darkMode
                    title: "Game history"
                    subtitle: "Replay finished games"
                    onClicked: homeScreen.navigateTo("GameHistoryScreen.qml")
                }

                MenuRow {
                    width: parent.width
                    darkMode: homeScreen.darkMode
                    title: "Settings"
                    subtitle: "Board, display, and gameplay"
                    onClicked: homeScreen.navigateTo("SettingsScreen.qml")
                }

                AppButton {
                    width: parent.width
                    compact: true
                    text: "Refresh"
                    onClicked: homeScreen.refresh()
                }
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "HomeState") {
            homeScreen.loadedOnce = true
            homeScreen.loadError = ""
            homeScreen.ongoingGames = msg.ongoing_games || []
            homeScreen.ratings = msg.ratings || []
        } else if (msg.type === "PendingChallenges") {
            homeScreen.challengesError = ""
            homeScreen.pendingChallengeId = ""
            homeScreen.pendingChallengeAction = ""
            homeScreen.pendingChallenges = msg.challenges || []
        } else if (msg.type === "ConnectivityState") {
            homeScreen.connectivityKnown = true
            homeScreen.online = msg.online || false
            homeScreen.wifiConnected = msg.wifi_connected !== undefined
                ? msg.wifi_connected
                : null
            homeScreen.connectionMessage = msg.message || ""
        } else if (msg.type === "HomeLoadFailed") {
            homeScreen.loadedOnce = true
            homeScreen.loadError = msg.message ||
                "Couldn't load your games. Check Wi-Fi and retry."
        } else if (msg.type === "ChallengesLoadFailed") {
            homeScreen.challengesError = msg.message ||
                "Couldn't load challenges."
        } else if (msg.type === "ErrorMsg") {
            homeScreen.pendingChallengeId = ""
            homeScreen.pendingChallengeAction = ""
            homeScreen.actionError = msg.message || "Lichess could not complete that action."
        }
    }
}
