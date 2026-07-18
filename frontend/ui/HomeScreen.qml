import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    anchors.fill: parent
    color: darkMode ? "#2b2b28" : "white"
    property var backendSender
    property var navigateTo
    property bool darkMode: false
    property var toggleDarkMode: function() {}
    property string resumableGameId: ""

    Column {
        anchors.centerIn: parent
        spacing: 24

        Text {
            text: "Lichess"
            font.pixelSize: 48
            color: darkMode ? "#e6e2d8" : "black"
        }

        Button {
            text: "Resume game"
            visible: resumableGameId.length > 0
            onClicked: {
                // There is no "resume" FrontendMessage: the per-game stream (Task 9) is
                // already running server-side and will emit BoardState on its own, and
                // main.qml's router (Task 10) auto-switches to BoardScreen.qml on the
                // first BoardState/GameOver/etc. regardless. We still navigate here for
                // an immediate UI transition instead of leaving Home showing while the
                // first BoardState is in flight.
                navigateTo("BoardScreen.qml")
            }
        }

        Button {
            text: "New game"
            onClicked: {
                navigateTo("SeekScreen.qml")
            }
        }

        Button {
            // Not a hardware light/warmth control -- reMarkable's frontlight is
            // brightness-only, no adjustable color temperature (see
            // docs/remarkable-appload-platform-notes.md). This just swaps this
            // app's own palette to a darker, e-ink-friendly (not pure black)
            // scheme. Unverified on real e-ink until an on-device pass; dark
            // fills are a plausible ghosting risk worth watching for.
            text: darkMode ? "Dark mode: On" : "Dark mode: Off"
            onClicked: toggleDarkMode()
        }
    }

    function handleMessage(msg) {
        if (msg.type === "HomeState") {
            resumableGameId = msg.resumable_game_id || ""
        }
    }
}
