import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: homeScreen
    anchors.fill: parent
    color: homeScreen.darkMode ? "#2b2b28" : "white"
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

    Column {
        anchors.centerIn: parent
        spacing: 24

        Text {
            text: "Lichess"
            font.pixelSize: 48
            color: homeScreen.darkMode ? "#e6e2d8" : "black"
        }

        Flow {
            width: parent.width
            spacing: 12
            visible: homeScreen.ratings.length > 0
            Repeater {
                model: homeScreen.ratings
                Text {
                    required property var modelData
                    text: modelData.speed + ": " + modelData.rating
                    font.pixelSize: 18
                    color: homeScreen.darkMode ? "#e6e2d8" : "black"
                }
            }
        }

        Repeater {
            model: homeScreen.ongoingGames
            // Same stacked-not-Row reasoning as pendingChallenges below -- a long
            // opponent name plus a Resume button doesn't reliably fit the device's
            // ~400px content width.
            Column {
                required property var modelData
                spacing: 4

                Text {
                    text: (modelData.opponent_name || "Opponent") +
                          (modelData.opponent_rating ? " (" + modelData.opponent_rating + ")" : "") +
                          (modelData.is_my_turn ? " -- your move" : " -- waiting")
                    font.pixelSize: 20
                    wrapMode: Text.WordWrap
                    width: homeScreen.width * 0.9
                    color: homeScreen.darkMode ? "#e6e2d8" : "black"
                }
                Button {
                    text: "Resume"
                    onClicked: {
                        // No BoardState flows for an already-in-progress game until its
                        // stream is (re)attached server-side -- see ResumeGame's own
                        // comment in protocol.rs. We still navigate immediately after
                        // for a responsive UI instead of waiting on the first BoardState.
                        homeScreen.backendSender({type: "ResumeGame", game_id: modelData.game_id})
                        homeScreen.navigateTo("BoardScreen.qml")
                    }
                }
            }
        }

        Button {
            text: "New game"
            onClicked: {
                homeScreen.navigateTo("SeekScreen.qml")
            }
        }

        Button {
            text: "Game history"
            onClicked: {
                homeScreen.backendSender({type: "RequestGameHistory"})
                homeScreen.navigateTo("GameHistoryScreen.qml")
            }
        }

        Button {
            // Not a hardware light/warmth control -- reMarkable's frontlight is
            // brightness-only, no adjustable color temperature (see
            // docs/remarkable-appload-platform-notes.md). This just swaps this
            // app's own palette to a darker, e-ink-friendly (not pure black)
            // scheme. Unverified on real e-ink until an on-device pass; dark
            // fills are a plausible ghosting risk worth watching for.
            text: homeScreen.darkMode ? "Dark mode: On" : "Dark mode: Off"
            onClicked: homeScreen.toggleDarkMode()
        }

        Button {
            text: "Settings"
            onClicked: homeScreen.navigateTo("SettingsScreen.qml")
        }

        Repeater {
            model: homeScreen.pendingChallenges
            // Stacked (text above buttons) rather than one Row -- a long
            // challenger name plus two buttons doesn't reliably fit the
            // device's ~400px content width, and a centered Column with no
            // fixed width won't wrap an overflowing Row, it'll just clip.
            Column {
                required property var modelData
                spacing: 4

                Text {
                    text: modelData.challenger + " challenges you (" + Math.floor((modelData.limit_seconds || 0) / 60) + "+" + (modelData.increment_seconds || 0) + ")"
                    font.pixelSize: 20
                    wrapMode: Text.WordWrap
                    width: homeScreen.width * 0.9
                    color: homeScreen.darkMode ? "#e6e2d8" : "black"
                }
                Row {
                    spacing: 8
                    Button {
                        text: "Accept"
                        onClicked: homeScreen.backendSender({type: "AcceptChallenge", id: modelData.id})
                    }
                    Button {
                        text: "Decline"
                        onClicked: homeScreen.backendSender({type: "DeclineChallenge", id: modelData.id})
                    }
                }
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "HomeState") {
            homeScreen.ongoingGames = msg.ongoing_games || []
            homeScreen.ratings = msg.ratings || []
        } else if (msg.type === "PendingChallenges") {
            homeScreen.pendingChallenges = msg.challenges || []
        }
    }
}
