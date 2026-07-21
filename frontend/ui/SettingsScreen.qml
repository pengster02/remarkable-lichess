import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: settingsScreen
    anchors.fill: parent
    color: settingsScreen.darkMode ? "#2b2b28" : "white"
    property var backendSender
    property var navigateTo
    property bool darkMode: false
    property var toggleDarkMode: function() {}
    // Pushed down from main.qml's root state (same pattern as darkMode) rather
    // than fetched fresh here -- persists across navigation and is kept in sync
    // by SaveSettings's own SettingsState echo, not just this screen's own guess.
    property bool autoQueenPromotion: false
    property var setAutoQueenPromotion: function() {}
    // Two-tap confirm, same pattern as BoardScreen's Resign button -- logging out
    // clears the saved token entirely (see backend_app.rs's handle_log_out), not
    // something a single mistaken tap should be able to do.
    property bool logOutArmed: false

    Column {
        anchors.centerIn: parent
        spacing: 24
        width: parent.width * 0.8

        Text {
            text: "Settings"
            font.pixelSize: 40
            color: settingsScreen.darkMode ? "#e6e2d8" : "black"
        }

        Button {
            // Not a hardware light/warmth control -- reMarkable's frontlight is
            // brightness-only, no adjustable color temperature (see
            // docs/remarkable-appload-platform-notes.md). This just swaps this
            // app's own palette to a darker, e-ink-friendly (not pure black) scheme.
            text: settingsScreen.darkMode ? "Dark mode: On" : "Dark mode: Off"
            onClicked: settingsScreen.toggleDarkMode()
        }

        // Confirmed against a real reference client, not invented for this app:
        // chess.com/World Chess's own help docs cover "premove, sounds, or the
        // auto-queen" as one of the standard settings every mainstream chess app
        // has. Off by default -- BoardScreen's promotion popup is the only way to
        // underpromote at all, so silently skipping it isn't the safer default.
        Button {
            text: "Auto-queen promotion: " + (settingsScreen.autoQueenPromotion ? "On" : "Off")
            onClicked: settingsScreen.setAutoQueenPromotion(!settingsScreen.autoQueenPromotion)
        }

        Button {
            text: "Back to Home"
            onClicked: settingsScreen.navigateTo("HomeScreen.qml")
        }

        Button {
            text: settingsScreen.logOutArmed ? "Tap again to log out" : "Log out"
            onClicked: {
                if (settingsScreen.logOutArmed) {
                    settingsScreen.backendSender({type: "LogOut"})
                    settingsScreen.logOutArmed = false
                } else {
                    settingsScreen.logOutArmed = true
                }
            }
        }
    }

    function handleMessage(msg) {
        // main.qml's router already updates root.autoQueenPromotion (and pushes it
        // back down here) on every SettingsState -- nothing left for this screen
        // to do with the message itself, but it still needs a handleMessage the
        // Loader can call without erroring, same as every other screen.
    }
}
