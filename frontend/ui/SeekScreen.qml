import QtQuick 2.5

Rectangle {
    id: seekScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: seekScreen.darkMode }
    property var backendSender
    property var navigateTo
    property bool darkMode: false
    // Set once SeekCreated/ChallengeCreated confirms the long-poll connection
    // backing the seek/challenge is actually held open server-side (see
    // backend_app.rs's pending_seek) -- Cancel only makes sense while it's live.
    property bool waiting: false
    property string waitingLabel: ""
    property bool rated: false
    // "white"/"black"/"random" -- same enum Lichess's own ChallengeColor.yaml
    // uses for both /api/board/seek and /api/challenge/{username}.
    property string selectedColor: "random"
    // {url, url_white, url_black} once OpenChallengeCreated arrives, else null.
    // Unlike waiting/waitingLabel above, an open challenge has no held-open
    // connection backing it (see backend_app.rs's create_open_challenge) --
    // the link stays valid on Lichess's side independent of this screen, so
    // there's deliberately no "Cancel" for it, just Back to Home.
    property var openChallengeUrls: null
    property string pendingAction: ""
    property string formError: ""

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

    function submitSeek() {
        // Lichess permits 180s on seeks but only 60s on challenges; one global
        // 60s cap hides valid seeks, while separate duplicate forms add drift.
        if (pendingAction.length > 0 || !validateTimeControl(180)) return
        pendingAction = "seek"
        backendSender({
            type: "CreateSeek",
            minutes: wholeNumber(minutesField.text),
            increment: wholeNumber(incrementField.text),
            rated: rated,
            color: selectedColor
        })
    }

    function submitChallenge() {
        if (pendingAction.length > 0 || !validateTimeControl(60)) return
        var username = usernameField.text.trim()
        if (username.length === 0) {
            formError = "Enter the Lichess username you want to challenge."
            return
        }
        pendingAction = "challenge"
        backendSender({
            type: "CreateChallenge",
            username: username,
            minutes: wholeNumber(minutesField.text),
            increment: wholeNumber(incrementField.text),
            rated: rated,
            color: selectedColor
        })
    }

    function submitOpenChallenge() {
        if (pendingAction.length > 0 || !validateTimeControl(60)) return
        pendingAction = "open"
        backendSender({
            type: "CreateOpenChallenge",
            minutes: wholeNumber(minutesField.text),
            increment: wholeNumber(incrementField.text),
            rated: rated
        })
    }

    function submitComputerGame() {
        if (pendingAction.length > 0 || !validateTimeControl(60)) return
        var level = wholeNumber(aiLevelField.text)
        if (isNaN(level) || level < 1 || level > 8) {
            formError = "Computer level must be a whole number from 1 to 8."
            return
        }
        pendingAction = "computer"
        backendSender({
            type: "ChallengeAi",
            level: level,
            minutes: wholeNumber(minutesField.text),
            increment: wholeNumber(incrementField.text)
        })
    }

    AppButton {
        id: backButton
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: theme.pageSideMargin
        width: Math.min(parent.width - theme.pageSideMargin * 2,
                        Math.max(theme.textFieldWidthMedium, naturalWidth))
        compact: true
        enabled: seekScreen.pendingAction.length === 0 || seekScreen.waiting
        text: "Back to Home"
        onClicked: {
            if (seekScreen.waiting) seekScreen.backendSender({type: "CancelSeek"})
            seekScreen.navigateTo("HomeScreen.qml")
        }
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
        anchors.bottom: backButton.top
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        anchors.bottomMargin: theme.spacingSmall
        contentHeight: seekColumn.height
        pageStops: seekScreen.waiting
            ? [0]
            : [0, playerChallengeSection.y]

    Column {
        id: seekColumn
        width: parent.width
        spacing: theme.spacingMedium

        AppPageHeader {
            width: parent.width
            darkMode: seekScreen.darkMode
            eyebrow: "Play"
            title: "New game"
            detail: "Set up your next game"
        }

        SectionCard {
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Time control"
            visible: !seekScreen.waiting

            Row {
                width: parent.width
                spacing: theme.spacingSmall
                Text { text: "Minutes"; font.pixelSize: theme.fontBody; width: parent.width - minutesField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: theme.text }
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
                Text { text: "Increment"; font.pixelSize: theme.fontBody; width: parent.width - incrementField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: theme.text }
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
        }

        SectionCard {
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Game preferences"
            visible: !seekScreen.waiting

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

        SectionCard {
            objectName: "seekErrorCard"
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Check game setup"
            visible: seekScreen.formError.length > 0

            Text {
                objectName: "seekErrorText"
                width: parent.width
                text: seekScreen.formError
                font.pixelSize: theme.fontBody
                wrapMode: Text.WordWrap
                color: theme.errorText
            }
        }

        AppButton {
            width: parent.width
            objectName: "findOpponentButton"
            text: seekScreen.pendingAction === "seek"
                ? "Finding an opponent…"
                : "Find an opponent"
            highlighted: true
            visible: !seekScreen.waiting
            enabled: seekScreen.pendingAction.length === 0
            onClicked: seekScreen.submitSeek()
        }

        SectionCard {
            id: playerChallengeSection
            objectName: "playerChallengeSection"
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Challenge a player"
            visible: !seekScreen.waiting
            AppTextField {
                id: usernameField
                objectName: "usernameField"
                font.pixelSize: theme.fontLarge
                placeholderText: "opponent username"
                width: parent.width
                onTextChanged: seekScreen.formError = ""
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
            visible: !seekScreen.waiting && seekScreen.openChallengeUrls === null
            enabled: seekScreen.pendingAction.length === 0
            onClicked: seekScreen.submitOpenChallenge()
        }

        Column {
            visible: seekScreen.openChallengeUrls !== null
            width: parent.width
            spacing: theme.spacingSmall

            Text {
                text: "Share one of these links — whoever opens it starts the game:"
                font.pixelSize: theme.fontLabel
                wrapMode: Text.WordWrap
                width: parent.width
                color: theme.text
            }
            TextEdit {
                readOnly: true
                selectByMouse: true
                width: parent.width
                wrapMode: Text.WrapAnywhere
                font.pixelSize: theme.fontSmall
                color: theme.text
                text: "White: " + (seekScreen.openChallengeUrls ? seekScreen.openChallengeUrls.url_white : "")
            }
            TextEdit {
                readOnly: true
                selectByMouse: true
                width: parent.width
                wrapMode: Text.WrapAnywhere
                font.pixelSize: theme.fontSmall
                color: theme.text
                text: "Black: " + (seekScreen.openChallengeUrls ? seekScreen.openChallengeUrls.url_black : "")
            }
        }

        SectionCard {
            id: computerSection
            objectName: "computerSection"
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Play the computer"
            visible: !seekScreen.waiting
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
            AppButton {
                objectName: "computerGameButton"
                width: parent.width
                text: seekScreen.pendingAction === "computer"
                    ? "Starting game…"
                    : "Start computer game"
                enabled: seekScreen.pendingAction.length === 0
                // Starts immediately -- no accept/decline step, so unlike the
                // seek/challenge buttons above there's no "waiting" state to enter;
                // the game arrives the same way any other game does, via the
                // account event stream's gameStart, and main.qml's router switches
                // to BoardScreen on the first BoardState like normal.
                onClicked: seekScreen.submitComputerGame()
            }
        }

        Text {
            text: seekScreen.waitingLabel
            visible: seekScreen.waiting
            font.pixelSize: theme.fontLarge
            color: theme.text
        }

        AppButton {
            width: parent.width
            text: "Cancel"
            visible: seekScreen.waiting
            onClicked: {
                seekScreen.backendSender({type: "CancelSeek"})
                seekScreen.waiting = false
                seekScreen.pendingAction = ""
            }
        }
        }
    }

    function handleMessage(msg) {
        // The actual transition to BoardScreen happens when main.qml's router
        // sees the first BoardState message arrive from the background game
        // stream once an opponent is found -- these two just confirm the
        // seek/challenge's long-poll connection is now held open server-side.
        if (msg.type === "SeekCreated") {
            seekScreen.pendingAction = ""
            seekScreen.formError = ""
            seekScreen.waiting = true
            seekScreen.waitingLabel = "Waiting for an opponent..."
        } else if (msg.type === "ChallengeCreated") {
            seekScreen.pendingAction = ""
            seekScreen.formError = ""
            seekScreen.waiting = true
            seekScreen.waitingLabel = "Challenge sent, waiting for a reply..."
        } else if (msg.type === "OpenChallengeCreated") {
            seekScreen.pendingAction = ""
            seekScreen.formError = ""
            seekScreen.openChallengeUrls = {url: msg.url, url_white: msg.url_white, url_black: msg.url_black}
        } else if (msg.type === "ErrorMsg") {
            seekScreen.pendingAction = ""
            seekScreen.formError = msg.message || "Lichess could not create that game."
        }
    }
}
