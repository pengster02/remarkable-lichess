import QtQuick 2.5

Rectangle {
    id: seekScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: seekScreen.darkMode }
    property var backendSender
    property var navigateTo
    property var openGame: function() {}
    property bool darkMode: false
    property bool waiting: false
    property string waitingLabel: ""
    property bool rated: false
    // "white"/"black"/"random" -- same enum Lichess's own ChallengeColor.yaml
    // uses for seeks, direct challenges, and computer games.
    property string selectedColor: "random"
    // The returned link remains usable after leaving this screen.
    property var openChallengeUrls: null
    property var nextRequestId
    property string pendingAction: ""
    property string waitingChallengeGameId: ""
    property int matchRequestId: 0
    property string seekMatchBeforeAckId: ""
    property bool seekEnded: false
    readonly property bool connectingMatch: pendingAction === "seek" || pendingAction === "challenge"
    readonly property bool creatingMatch: pendingAction === "open" || pendingAction === "computer"
    readonly property bool canCancelMatch: matchRequestId > 0 && (connectingMatch || waiting)
    readonly property bool showingSetup: !waiting && !connectingMatch && !seekEnded
    readonly property bool canSubmit: !waiting && pendingAction.length === 0
    property string formError: ""
    readonly property bool keyboardActive: minutesField.activeFocus ||
        incrementField.activeFocus || usernameField.activeFocus ||
        aiLevelField.activeFocus

    Component.onDestruction: {
        if (seekScreen.matchRequestId > 0 && seekScreen.backendSender)
            seekScreen.backendSender({type: "CancelMatch", request_id: seekScreen.matchRequestId})
    }

    Timer {
        id: seekSettlement
        // EOF can precede the separate game event. Ending immediately loses
        // that match, while waiting forever strands the expired seek.
        interval: 5000
        onTriggered: {
            seekScreen.clearWaiting()
            seekScreen.seekEnded = true
        }
    }

    // A plain “10 + 0” is compact but opaque on a setup form. Alternatives were
    // unit suffixes inside editable fields, or preset-only time controls.
    readonly property string timeControlSummary: {
        var minutes = wholeNumber(minutesField.text)
        var increment = wholeNumber(incrementField.text)
        if (isNaN(minutes) || isNaN(increment)) return "Enter a time control"
        return minutes + (minutes === 1 ? " minute" : " minutes") +
            " + " + increment + (increment === 1 ? " second" : " seconds") +
            " per move"
    }

    function wholeNumber(text) {
        var trimmed = text.trim()
        return /^\d+$/.test(trimmed) ? Number(trimmed) : NaN
    }

    function timeControlError(maximumIncrement) {
        var minutes = wholeNumber(minutesField.text)
        var increment = wholeNumber(incrementField.text)
        if (isNaN(minutes)) return "Minutes must be a whole number."
        if (minutes < 0 || minutes > 180) return "Minutes must be between 0 and 180."
        if (isNaN(increment)) return "Increment must be a whole number."
        if (increment < 0 || increment > maximumIncrement)
            return "Increment must be between 0 and " + maximumIncrement + "."
        if (minutes === 0 && increment === 0) return "Choose some starting time or an increment."
        return ""
    }

    function validateTimeControl(maximumIncrement) {
        formError = timeControlError(maximumIncrement)
        return formError.length === 0
    }

    function dismissKeyboard() {
        minutesField.focus = false
        incrementField.focus = false
        usernameField.focus = false
        aiLevelField.focus = false
        seekScreen.forceActiveFocus()
        Qt.inputMethod.hide()
    }

    function submitSeek() {
        // Lichess permits 180s on seeks but only 60s on challenges; one global
        // 60s cap hides valid seeks, while separate duplicate forms add drift.
        if (!canSubmit || !validateTimeControl(180)) return
        dismissKeyboard()
        matchRequestId = nextRequestId()
        seekMatchBeforeAckId = ""
        seekEnded = false
        waitingLabel = "Connecting to matchmaking…"
        formError = ""
        pendingAction = "seek"
        backendSender({
            type: "CreateSeek",
            request_id: matchRequestId,
            minutes: wholeNumber(minutesField.text),
            increment: wholeNumber(incrementField.text),
            rated: rated,
            color: selectedColor
        })
    }

    function clearWaiting() {
        seekSettlement.stop()
        waiting = false
        waitingChallengeGameId = ""
        matchRequestId = 0
        seekMatchBeforeAckId = ""
    }

    function cancelWaiting() {
        var requestId = matchRequestId
        pendingAction = ""
        clearWaiting()
        if (requestId > 0) backendSender({type: "CancelMatch", request_id: requestId})
    }

    function openMatchedGame(gameId) {
        cancelWaiting()
        openGame(gameId)
    }

    function revealChallengeSetup() {
        if (!seekScreen.showingSetup || !seekScreen.canSubmit || !seekScreen.formError) return
        // Waiting shrinks the pager. Remembered offsets can drift, and the first page can hide the retry.
        seekColumn.forceLayout()
        seekPager.showPageContaining(playerChallengeSection.y, playerChallengeSection.height)
    }

    function revealOpenChallenge() {
        if (!openChallengeShare.visible) return
        seekColumn.forceLayout()
        seekPager.showPageContaining(openChallengeShare.y, openChallengeShare.height)
    }

    function submitChallenge() {
        if (!showingSetup || !canSubmit || !validateTimeControl(60)) return
        var username = usernameField.text.trim()
        if (username.length === 0) {
            formError = "Enter the Lichess username you want to challenge."
            return
        }
        dismissKeyboard()
        matchRequestId = nextRequestId()
        waitingLabel = "Sending challenge…"
        formError = ""
        pendingAction = "challenge"
        backendSender({
            type: "CreateChallenge",
            request_id: matchRequestId,
            username: username,
            minutes: wholeNumber(minutesField.text),
            increment: wholeNumber(incrementField.text),
            rated: rated,
            color: selectedColor
        })
    }

    function submitOpenChallenge() {
        if (!showingSetup || !canSubmit || openChallengeUrls !== null || !validateTimeControl(60)) return
        dismissKeyboard()
        matchRequestId = nextRequestId()
        pendingAction = "open"
        backendSender({
            type: "CreateOpenChallenge",
            request_id: matchRequestId,
            minutes: wholeNumber(minutesField.text),
            increment: wholeNumber(incrementField.text),
            rated: rated
        })
    }

    function submitComputerGame() {
        if (!showingSetup || !canSubmit || !validateTimeControl(60)) return
        var level = wholeNumber(aiLevelField.text)
        if (isNaN(level) || level < 1 || level > 8) {
            formError = "Computer level must be a whole number from 1 to 8."
            return
        }
        dismissKeyboard()
        matchRequestId = nextRequestId()
        pendingAction = "computer"
        backendSender({
            type: "ChallengeAi",
            request_id: matchRequestId,
            level: level,
            minutes: wholeNumber(minutesField.text),
            increment: wholeNumber(incrementField.text),
            color: selectedColor
        })
    }

    AppButton {
        id: backButton
        objectName: "matchBackButton"
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: theme.pageSideMargin
        width: Math.min(parent.width - theme.pageSideMargin * 2,
                        Math.max(theme.textFieldWidthMedium, naturalWidth))
        compact: true
        text: "Back to Home"
        onClicked: {
            seekScreen.dismissKeyboard()
            seekScreen.cancelWaiting()
            seekScreen.navigateTo("HomeScreen.qml")
        }
    }

    // Keep one error outside the pager. Inline feedback can be clipped, while a dialog blocks correction.
    Text {
        id: setupError
        objectName: "seekErrorText"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: backButton.top
        anchors.margins: theme.pageSideMargin
        anchors.bottomMargin: theme.spacingSmall
        visible: seekScreen.formError.length > 0
        text: seekScreen.formError
        textFormat: Text.PlainText
        font.pixelSize: theme.fontLabel
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        color: theme.errorText
    }

    EinkPagedFlickable {
        id: seekPager
        objectName: "seekFlickable"
        // Top-anchored (was `anchors.centerIn: parent`) for the same
        // cross-page-alignment reason as SettingsScreen, and for a more
        // concrete reason specific to this screen: centered content this
        // tall (title + time/increment row + rated checkbox + color row +
        // three action rows + AI row, each using this session's bumped-up
        // fontLarge/spacingLarge) very plausibly doesn't fit centered within
        // this device's actual screen height without a scroll -- a plain
        // centered Column has no scrolling at all, so anything that didn't
        // fit was simply unreachable off both the top and bottom edges.
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: setupError.visible ? setupError.top : backButton.top
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        anchors.bottomMargin: theme.spacingSmall
        contentHeight: seekColumn.height
        onPageNavigationRequested: seekScreen.dismissKeyboard()
        pageStops: {
            if (!seekScreen.showingSetup) return [0]
            var stops = [0, playerChallengeSection.y]
            // A result anchor is needed only if the preceding page would
            // clip the card. Always adding one repeats a page on larger screens.
            if (openChallengeShare.visible && openChallengeShare.y + openChallengeShare.height >
                    playerChallengeSection.y + seekPager.pageHeight + seekPager.positionTolerance) {
                stops.push(openChallengeShare.y)
            }
            return stops
        }

    Column {
        id: seekColumn
        width: parent.width
        spacing: theme.spacingMedium

        AppPageHeader {
            width: parent.width
            darkMode: seekScreen.darkMode
            eyebrow: "Play"
            title: "New game"
            detail: seekScreen.showingSetup ? "Set up your next game" : ""
        }

        SectionCard {
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Time control"
            visible: seekScreen.showingSetup

            Text {
                objectName: "timeControlSummary"
                width: parent.width
                text: seekScreen.timeControlSummary
                font.pixelSize: theme.fontLarge
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: theme.text
            }

            Row {
                width: parent.width
                spacing: theme.spacingSmall
                Text { text: "Starting minutes"; font.pixelSize: theme.fontBody; width: parent.width - minutesField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: theme.text }
                AppTextField {
                    id: minutesField
                    objectName: "minutesField"
                    text: "10"
                    font.pixelSize: theme.fontLarge
                    width: theme.textFieldWidthNarrow
                    inputMethodHints: Qt.ImhDigitsOnly
                    onTextChanged: seekScreen.formError = ""
                }
            }

            Row {
                width: parent.width
                spacing: theme.spacingSmall
                Text { text: "Seconds added per move"; font.pixelSize: theme.fontBody; width: parent.width - incrementField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: theme.text }
                AppTextField {
                    id: incrementField
                    objectName: "incrementField"
                    text: "0"
                    font.pixelSize: theme.fontLarge
                    width: theme.textFieldWidthNarrow
                    inputMethodHints: Qt.ImhDigitsOnly
                    onTextChanged: seekScreen.formError = ""
                }
            }

            KeyboardDismissButton {
                objectName: "timeKeyboardDoneButton"
                width: parent.width
                editing: minutesField.activeFocus || incrementField.activeFocus
                onDismissRequested: seekScreen.dismissKeyboard()
            }
        }

        SectionCard {
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Game preferences"
            visible: seekScreen.showingSetup

            Text { text: "Game type"; font.pixelSize: theme.fontLabel; color: theme.textMuted }
            SegmentedControl {
                objectName: "gameTypeControl"
                width: parent.width
                darkMode: seekScreen.darkMode
                options: [
                    {id: "casual", label: "Casual"},
                    {id: "rated", label: "Rated"}
                ]
                value: seekScreen.rated ? "rated" : "casual"
                onSelected: (value) => seekScreen.rated = value === "rated"
            }

            Text { text: "Your color"; font.pixelSize: theme.fontLabel; color: theme.textMuted }
            SegmentedControl {
                objectName: "colorControl"
                width: parent.width
                darkMode: seekScreen.darkMode
                options: [
                    {id: "white", label: "White"},
                    {id: "black", label: "Black"},
                    {id: "random", label: "Random"}
                ]
                value: seekScreen.selectedColor
                onSelected: (value) => seekScreen.selectedColor = value
            }
        }

        Text {
            objectName: "seekEndedNotice"
            width: parent.width
            visible: seekScreen.seekEnded
            text: "Search ended. Check Home for a match."
            wrapMode: Text.WordWrap
            font.pixelSize: theme.fontLabel
            color: theme.textMuted
        }

        AppButton {
            width: parent.width
            objectName: "findOpponentButton"
            text: seekScreen.seekEnded ? "Search again" : "Find an opponent"
            highlighted: true
            visible: seekScreen.showingSetup || seekScreen.seekEnded
            enabled: seekScreen.pendingAction.length === 0
            onClicked: seekScreen.submitSeek()
        }

        AppButton {
            width: parent.width
            objectName: "editSeekSetupButton"
            text: "Edit game setup"
            visible: seekScreen.seekEnded
            enabled: seekScreen.pendingAction.length === 0
            onClicked: seekScreen.seekEnded = false
        }

        SectionCard {
            id: playerChallengeSection
            objectName: "playerChallengeSection"
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Challenge a player"
            visible: seekScreen.showingSetup
            AppTextField {
                id: usernameField
                objectName: "usernameField"
                font.pixelSize: theme.fontLarge
                placeholderText: "opponent username"
                width: parent.width
                onTextChanged: seekScreen.formError = ""
            }
            KeyboardDismissButton {
                objectName: "usernameKeyboardDoneButton"
                width: parent.width
                editing: usernameField.activeFocus
                onDismissRequested: seekScreen.dismissKeyboard()
            }
            AppButton {
                objectName: "challengePlayerButton"
                width: parent.width
                text: seekScreen.pendingAction === "challenge"
                    ? "Sending challenge…"
                    : "Challenge"
                enabled: seekScreen.pendingAction.length === 0
                onClicked: seekScreen.submitChallenge()
            }
        }

        AppButton {
            objectName: "openChallengeButton"
            width: parent.width
            text: seekScreen.pendingAction === "open"
                ? "Creating link…"
                : "Create a shareable challenge"
            visible: seekScreen.showingSetup && seekScreen.openChallengeUrls === null
            enabled: seekScreen.pendingAction.length === 0
            onClicked: seekScreen.submitOpenChallenge()
        }

        OpenChallengeShare {
            id: openChallengeShare
            objectName: "openChallengeShare"
            width: parent.width
            visible: seekScreen.showingSetup && seekScreen.openChallengeUrls !== null
            links: seekScreen.openChallengeUrls
            darkMode: seekScreen.darkMode
        }

        SectionCard {
            id: computerSection
            objectName: "computerSection"
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Play the computer"
            visible: seekScreen.showingSetup
            Row {
                width: parent.width
                spacing: theme.spacingSmall
                Text { text: "Computer level (1-8)"; font.pixelSize: theme.fontBody; width: parent.width - aiLevelField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: theme.text }
                AppTextField {
                    id: aiLevelField
                    objectName: "aiLevelField"
                    text: "3"
                    font.pixelSize: theme.fontLarge
                    width: theme.textFieldWidthNarrow
                    inputMethodHints: Qt.ImhDigitsOnly
                    onTextChanged: seekScreen.formError = ""
                }
            }
            KeyboardDismissButton {
                objectName: "computerKeyboardDoneButton"
                width: parent.width
                editing: aiLevelField.activeFocus
                onDismissRequested: seekScreen.dismissKeyboard()
            }
            AppButton {
                objectName: "computerGameButton"
                width: parent.width
                text: seekScreen.pendingAction === "computer"
                    ? "Starting game…"
                    : "Start computer game"
                enabled: seekScreen.pendingAction.length === 0
                onClicked: seekScreen.submitComputerGame()
            }
        }

        Text {
            text: seekScreen.waitingLabel
            visible: seekScreen.connectingMatch || seekScreen.waiting
            font.pixelSize: theme.fontLarge
            color: theme.text
        }

        AppButton {
            objectName: "cancelMatchButton"
            width: parent.width
            text: "Cancel"
            visible: seekScreen.canCancelMatch
            onClicked: seekScreen.cancelWaiting()
        }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "SeekCreated") {
            if (seekScreen.pendingAction !== "seek" || msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.pendingAction = ""
            seekScreen.formError = ""
            seekScreen.seekEnded = false
            seekScreen.waiting = true
            seekScreen.waitingLabel = "Waiting for an opponent..."
            if (seekScreen.seekMatchBeforeAckId) seekScreen.openMatchedGame(seekScreen.seekMatchBeforeAckId)
        } else if (msg.type === "SeekFailed") {
            if (seekScreen.pendingAction !== "seek" || msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.pendingAction = ""
            seekScreen.clearWaiting()
            seekScreen.seekEnded = false
            seekScreen.formError = msg.message || "Lichess could not find an opponent."
        } else if (msg.type === "SeekEnded") {
            if (!seekScreen.waiting || msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.waitingLabel = "Checking for a match..."
            seekSettlement.start()
        } else if (msg.type === "ChallengeCreated") {
            if (seekScreen.pendingAction !== "challenge" || msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.pendingAction = ""
            seekScreen.formError = ""
            seekScreen.waiting = true
            seekScreen.waitingChallengeGameId = msg.game_id
            seekScreen.waitingLabel = "Challenge sent, waiting for a reply..."
        } else if (msg.type === "ChallengeCreateFailed") {
            if (seekScreen.pendingAction !== "challenge" || msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.pendingAction = ""
            seekScreen.clearWaiting()
            seekScreen.formError = msg.message || "Lichess could not create the challenge."
            Qt.callLater(seekScreen.revealChallengeSetup)
        } else if (msg.type === "ChallengeResolved") {
            if (!seekScreen.waiting || msg.game_id !== seekScreen.waitingChallengeGameId ||
                    msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.clearWaiting()
            if (msg.error) {
                seekScreen.formError = msg.error
                Qt.callLater(seekScreen.revealChallengeSetup)
            } else {
                seekScreen.openGame(msg.game_id)
            }
        } else if (msg.type === "ComputerGameCreated") {
            if (seekScreen.pendingAction !== "computer" || msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.pendingAction = ""
            seekScreen.clearWaiting()
            seekScreen.openGame(msg.game_id)
        } else if (msg.type === "OpenChallengeCreated") {
            if (seekScreen.pendingAction !== "open" || msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.pendingAction = ""
            seekScreen.clearWaiting()
            seekScreen.formError = ""
            seekScreen.openChallengeUrls = msg
            Qt.callLater(seekScreen.revealOpenChallenge)
        } else if (msg.type === "MatchCreationFailed") {
            if (!seekScreen.creatingMatch || msg.request_id !== seekScreen.matchRequestId) return
            seekScreen.pendingAction = ""
            seekScreen.clearWaiting()
            seekScreen.formError = msg.message || "Lichess could not create that game."
        } else if (msg.type === "GameStarted") {
            var lookingForOpponent = seekScreen.waiting && seekScreen.waitingChallengeGameId.length === 0
            var matchingLink = seekScreen.pendingAction.length === 0 && !seekScreen.waiting &&
                seekScreen.openChallengeUrls && msg.game_id === seekScreen.openChallengeUrls.game_id
            if (lookingForOpponent && msg.from_realtime_lobby)
                seekScreen.openMatchedGame(msg.game_id)
            else if (matchingLink)
                seekScreen.openGame(msg.game_id)
            else if (seekScreen.pendingAction === "seek" && msg.from_realtime_lobby &&
                     !seekScreen.seekMatchBeforeAckId)
                seekScreen.seekMatchBeforeAckId = msg.game_id
        } else if (msg.type === "ErrorMsg") {
            if (seekScreen.matchRequestId > 0) return
            seekScreen.formError = msg.message || "Lichess could not create that game."
        }
    }
}
