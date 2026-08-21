import QtQuick 2.5

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
    property bool minimalHighlights: true
    property var setMinimalHighlights: function() {}
    property bool premovesEnabled: false
    property var setPremovesEnabled: function() {}
    property bool liveClockEnabled: true
    property var setLiveClockEnabled: function() {}
    property string boardTheme: "brown"
    property var setBoardTheme: function() {}
    property string pieceSet: "cburnett"
    property var setPieceSet: function() {}
    property bool showCoordinates: true
    property var setShowCoordinates: function() {}
    property bool showCapturedPieces: true
    property var setShowCapturedPieces: function() {}
    property bool highlightLastMove: true
    property var setHighlightLastMove: function() {}
    property bool confirmResign: false
    property var setConfirmResign: function() {}
    // Two-tap confirm, same pattern as BoardScreen's Resign button -- logging out
    // clears the saved token entirely (see backend_app.rs's handle_log_out), not
    // something a single mistaken tap should be able to do.
    property bool logOutArmed: false
    property string saveError: ""
    property bool rollbackRequested: false

    BoardStyle {
        id: appearanceStyle
        darkMode: settingsScreen.darkMode
        boardTheme: settingsScreen.boardTheme
        pieceSet: settingsScreen.pieceSet
    }

    AppButton {
        id: backButton
        objectName: "settingsBackButton"
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: theme.pageSideMargin
        width: Math.min(parent.width - theme.pageSideMargin * 2,
                        Math.max(theme.textFieldWidthMedium, naturalWidth))
        compact: true
        text: "Back to Home"
        onClicked: settingsScreen.navigateTo("HomeScreen.qml")
    }

    EinkPagedFlickable {
        id: settingsPager
        objectName: "settingsFlickable"
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
        contentHeight: settingsColumn.height
        pageStops: [0, displaySection.y, gameplaySection.y]

        Column {
            id: settingsColumn
            objectName: "settingsColumn"
            width: parent.width
            spacing: theme.spacingSmall

            AppPageHeader {
                width: parent.width
                darkMode: settingsScreen.darkMode
                eyebrow: "Preferences"
                title: "Settings"
                detail: "Board, display, and gameplay"
            }

            SectionCard {
                objectName: "settingsSaveErrorCard"
                width: parent.width
                darkMode: settingsScreen.darkMode
                compact: true
                title: "Settings not saved"
                visible: settingsScreen.saveError.length > 0

                Text {
                    width: parent.width
                    text: settingsScreen.saveError
                    font.pixelSize: theme.fontBody
                    wrapMode: Text.WordWrap
                    color: theme.errorText
                }

                AppButton {
                    width: parent.width
                    compact: true
                    text: "Dismiss"
                    onClicked: settingsScreen.saveError = ""
                }
            }

            SectionCard {
                id: appearanceSection
                objectName: "appearanceSection"
                darkMode: settingsScreen.darkMode
                compact: true
                title: "Appearance"
                width: parent.width

                SettingsToggle {
                    objectName: "darkModeSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Dark mode"
                    value: settingsScreen.darkMode
                    onToggled: settingsScreen.toggleDarkMode()
                }

                Text {
                    width: parent.width
                    text: "Board preview  ·  " + appearanceStyle.boardLabel() +
                        " / " + appearanceStyle.pieceLabel()
                    font.pixelSize: theme.fontBody
                    font.bold: true
                    color: theme.text
                    horizontalAlignment: Text.AlignHCenter
                }

                BoardPreview {
                    objectName: "appearanceBoardPreview"
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(parent.width, 400)
                    height: width
                    darkMode: settingsScreen.darkMode
                    boardTheme: settingsScreen.boardTheme
                    pieceSet: settingsScreen.pieceSet
                }

                Text {
                    width: parent.width
                    text: "Board color"
                    font.pixelSize: theme.fontLabel
                    font.bold: true
                    color: theme.text
                }

                SegmentedControl {
                    objectName: "boardThemeControl"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    options: appearanceStyle.boardOptions
                    value: settingsScreen.boardTheme
                    onSelected: (value) => settingsScreen.setBoardTheme(value)
                }

                Text {
                    width: parent.width
                    text: "Chess pieces"
                    font.pixelSize: theme.fontLabel
                    font.bold: true
                    color: theme.text
                }

                SegmentedControl {
                    objectName: "pieceSetControl"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    options: appearanceStyle.pieceOptions
                    value: settingsScreen.pieceSet
                    onSelected: (value) => settingsScreen.setPieceSet(value)
                }

            }

            SectionCard {
                id: displaySection
                objectName: "displaySection"
                darkMode: settingsScreen.darkMode
                compact: true
                title: "Board display"
                width: parent.width

                SettingsToggle {
                    objectName: "minimalHighlightsSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Minimal highlights"
                    value: settingsScreen.minimalHighlights
                    onToggled: settingsScreen.setMinimalHighlights(!settingsScreen.minimalHighlights)
                }

                SettingsToggle {
                    objectName: "coordinatesSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Board coordinates"
                    value: settingsScreen.showCoordinates
                    onToggled: settingsScreen.setShowCoordinates(!settingsScreen.showCoordinates)
                }

                SettingsToggle {
                    objectName: "capturedPiecesSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Captured pieces"
                    value: settingsScreen.showCapturedPieces
                    onToggled: settingsScreen.setShowCapturedPieces(!settingsScreen.showCapturedPieces)
                }

                SettingsToggle {
                    objectName: "lastMoveSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Highlight last move"
                    value: settingsScreen.highlightLastMove
                    onToggled: settingsScreen.setHighlightLastMove(!settingsScreen.highlightLastMove)
                }
            }

            SectionCard {
                id: gameplaySection
                objectName: "gameplaySection"
                darkMode: settingsScreen.darkMode
                compact: true
                title: "Gameplay"
                width: parent.width

                SettingsToggle {
                    objectName: "autoQueenSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Auto-queen promotion"
                    value: settingsScreen.autoQueenPromotion
                    onToggled: settingsScreen.setAutoQueenPromotion(!settingsScreen.autoQueenPromotion)
                }

                SettingsToggle {
                    objectName: "confirmMovesSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Confirm moves"
                    value: settingsScreen.moveConfirmation
                    onToggled: settingsScreen.setMoveConfirmation(!settingsScreen.moveConfirmation)
                }

                SettingsToggle {
                    objectName: "premovesSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Premoves"
                    value: settingsScreen.premovesEnabled
                    onToggled: settingsScreen.setPremovesEnabled(!settingsScreen.premovesEnabled)
                }

                SettingsToggle {
                    objectName: "liveClockSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Live clock"
                    value: settingsScreen.liveClockEnabled
                    onToggled: settingsScreen.setLiveClockEnabled(!settingsScreen.liveClockEnabled)
                }

                SettingsToggle {
                    objectName: "confirmResignSetting"
                    width: parent.width
                    darkMode: settingsScreen.darkMode
                    label: "Confirm resign / abort"
                    value: settingsScreen.confirmResign
                    onToggled: settingsScreen.setConfirmResign(!settingsScreen.confirmResign)
                }
            }

            SectionCard {
                id: accountSection
                darkMode: settingsScreen.darkMode
                compact: true
                title: "Account"
                width: parent.width

                AppButton {
                    width: parent.width
                    compact: true
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
        if (msg.type === "ErrorMsg") {
            settingsScreen.saveError = msg.message || "The new settings could not be saved."
            // Reloading persisted state prevents the optimistic toggle from lying;
            // leaving it changed or reverting one field locally can both drift.
            if (!settingsScreen.rollbackRequested) {
                settingsScreen.rollbackRequested = true
                settingsScreen.backendSender({type: "RequestSettings"})
            }
        } else if (msg.type === "SettingsState") {
            settingsScreen.rollbackRequested = false
        }
    }
}
