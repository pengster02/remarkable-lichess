import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: homeScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: homeScreen.darkMode }
    property var backendSender
    property var navigateTo
    property bool darkMode: false
    property var toggleDarkMode: function() {}
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

    onBackendSenderChanged: {
        if (homeScreen.backendSender) {
            homeScreen.backendSender({type: "RequestHome"})
            homeScreen.backendSender({type: "RequestChallenges"})
        }
    }

    Flickable {
        anchors.fill: parent
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        contentWidth: width
        contentHeight: contentColumn.height
        // No rubber-band overshoot at the ends -- same reasoning as every
        // other Flickable/ListView in this app (see GameHistoryScreen's own
        // comment on this): that bounce is itself a multi-frame animation,
        // a real e-ink refresh cost for a purely cosmetic effect. This one
        // was missing it before this pass -- the one Flickable in the app
        // that had drifted from that rule.
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: contentColumn
            width: parent.width
            spacing: theme.spacingMedium

            Column {
                width: parent.width
                spacing: theme.spacingSmall
                Image {
                    anchors.horizontalCenter: parent.horizontalCenter
                    source: "../assets/pieces/cburnett/wN.png"
                    width: 150
                    height: 150
                    fillMode: Image.PreserveAspectFit
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Lichess"
                    font.pixelSize: theme.fontDisplay
                    font.bold: true
                    color: theme.text
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: homeScreen.username.length > 0
                    text: homeScreen.username
                    font.pixelSize: theme.fontBody
                    color: theme.textMuted
                }
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
                            text: modelData.speed.charAt(0).toUpperCase() + modelData.speed.slice(1) + "  <b>" + modelData.rating + "</b>"
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
                                  (modelData.is_my_turn ? " -- your move" : " -- waiting")
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
                                text: "Accept"
                                highlighted: true
                                onClicked: homeScreen.backendSender({type: "AcceptChallenge", id: modelData.id})
                            }
                            AppButton {
                                width: (parent.width - theme.spacingSmall) / 2
                                text: "Decline"
                                onClicked: homeScreen.backendSender({type: "DeclineChallenge", id: modelData.id})
                            }
                        }
                    }
                }
            }

            // Full-width navigation rows (was a Flow of shrink-wrapped
            // buttons whose widths varied with their own label lengths) --
            // the e-ink list convention: every primary destination is one
            // unmissable full-width target, stacked, identical in size.
            // "New game" is the primary action and gets the accent.
            Column {
                width: parent.width
                spacing: theme.spacingSmall

                AppButton {
                    width: parent.width
                    text: "New game"
                    highlighted: true
                    onClicked: homeScreen.navigateTo("SeekScreen.qml")
                }

                AppButton {
                    width: parent.width
                    text: "Game history"
                    onClicked: homeScreen.navigateTo("GameHistoryScreen.qml")
                }

                AppButton {
                    // Not a hardware light/warmth control -- reMarkable's frontlight
                    // is brightness-only, no adjustable color temperature (see
                    // docs/remarkable-appload-platform-notes.md). This just swaps
                    // this app's own palette to a darker, e-ink-friendly (not pure
                    // black) scheme. Unverified on real e-ink until an on-device
                    // pass; dark fills are a plausible ghosting risk worth watching
                    // for.
                    width: parent.width
                    text: homeScreen.darkMode ? "Dark mode: On" : "Dark mode: Off"
                    onClicked: homeScreen.toggleDarkMode()
                }

                AppButton {
                    width: parent.width
                    text: "Settings"
                    onClicked: homeScreen.navigateTo("SettingsScreen.qml")
                }
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "HomeState") {
            homeScreen.loadedOnce = true
            homeScreen.ongoingGames = msg.ongoing_games || []
            homeScreen.ratings = msg.ratings || []
        } else if (msg.type === "PendingChallenges") {
            homeScreen.pendingChallenges = msg.challenges || []
        }
    }
}
