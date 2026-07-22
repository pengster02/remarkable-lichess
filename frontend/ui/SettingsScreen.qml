import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: settingsScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: settingsScreen.darkMode }
    property var backendSender
    property var navigateTo
    property bool darkMode: false
    property var toggleDarkMode: function() {}
    // Pushed down from main.qml's root state (same pattern as darkMode) rather
    // than fetched fresh here -- persists across navigation and is kept in sync
    // by SaveSettings's own SettingsState echo, not just this screen's own guess.
    property bool autoQueenPromotion: false
    property var setAutoQueenPromotion: function() {}
    property bool moveConfirmation: false
    property var setMoveConfirmation: function() {}
    property bool minimalHighlights: false
    property var setMinimalHighlights: function() {}
    // Two-tap confirm, same pattern as BoardScreen's Resign button -- logging out
    // clears the saved token entirely (see backend_app.rs's handle_log_out), not
    // something a single mistaken tap should be able to do.
    property bool logOutArmed: false

    Button {
        id: backButton
        // Same fixed, full-width bottom "nav bar" treatment as every other
        // screen's back action -- previously just the last item in this
        // screen's own centered Column, i.e. wherever that column happened
        // to end, unlike GameHistoryScreen/GameReviewScreen's fixed bottom
        // placement.
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        text: "Back to Home"
        onClicked: settingsScreen.navigateTo("HomeScreen.qml")
    }

    Flickable {
        // Top-anchored like every other screen now (was `anchors.centerIn:
        // parent`) -- centering made this screen's title/cards start at a
        // different y-offset than every top-anchored screen's own header,
        // the exact cross-page misalignment this pass exists to fix. Wrapped
        // in a Flickable (was a plain Column) since a real account with
        // every SectionCard's content visible plus this session's font/
        // spacing bump is a real risk of not fitting in the vertical space
        // above the fixed Back button on this device's actual screen height.
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: backButton.top
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        anchors.bottomMargin: theme.spacingSmall
        contentWidth: width
        contentHeight: settingsColumn.height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
            id: settingsColumn
            width: parent.width
            spacing: theme.spacingMedium

            Text {
                text: "Settings"
                font.pixelSize: theme.fontHeading
                font.bold: true
                color: theme.text
            }

            SectionCard {
                darkMode: settingsScreen.darkMode
                title: "Appearance"
                width: parent.width

                Button {
                    // Not a hardware light/warmth control -- reMarkable's frontlight is
                    // brightness-only, no adjustable color temperature (see
                    // docs/remarkable-appload-platform-notes.md). This just swaps this
                    // app's own palette to a darker, e-ink-friendly (not pure black) scheme.
                    text: settingsScreen.darkMode ? "Dark mode: On" : "Dark mode: Off"
                    onClicked: settingsScreen.toggleDarkMode()
                }

                // Tap-to-select highlights every legal destination square (up
                // to ~28 of them scattered across the board) in addition to
                // the selected square itself -- real, visible redraw damage
                // on e-ink for state that's purely a convenience cue. Off by
                // default: full highlighting is more helpful day-to-day, this
                // just offers the tradeoff to whoever wants faster feedback
                // over it.
                Button {
                    text: "Minimal highlights: " + (settingsScreen.minimalHighlights ? "On" : "Off")
                    onClicked: settingsScreen.setMinimalHighlights(!settingsScreen.minimalHighlights)
                }
            }

            SectionCard {
                darkMode: settingsScreen.darkMode
                title: "Gameplay"
                width: parent.width

                // Confirmed against a real reference client, not invented for this app:
                // chess.com/World Chess's own help docs cover "premove, sounds, or the
                // auto-queen" as one of the standard settings every mainstream chess app
                // has. Off by default -- BoardScreen's promotion popup is the only way to
                // underpromote at all, so silently skipping it isn't the safer default.
                Button {
                    text: "Auto-queen promotion: " + (settingsScreen.autoQueenPromotion ? "On" : "Off")
                    onClicked: settingsScreen.setAutoQueenPromotion(!settingsScreen.autoQueenPromotion)
                }

                // Confirmed against the official lichess-org/mobile app's own
                // moveToConfirm/confirmMove/cancelMove -- default off there
                // too, same as auto-queen above: BoardScreen's own tap-to-move
                // is already the fast path, so silently gating every move
                // behind an extra tap isn't the safer default either.
                Button {
                    text: "Confirm moves: " + (settingsScreen.moveConfirmation ? "On" : "Off")
                    onClicked: settingsScreen.setMoveConfirmation(!settingsScreen.moveConfirmation)
                }
            }

            SectionCard {
                darkMode: settingsScreen.darkMode
                title: "Account"
                width: parent.width

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
        }
    }

    function handleMessage(msg) {
        // main.qml's router already updates root.autoQueenPromotion (and pushes it
        // back down here) on every SettingsState -- nothing left for this screen
        // to do with the message itself, but it still needs a handleMessage the
        // Loader can call without erroring, same as every other screen.
    }
}
