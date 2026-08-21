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

    AppButton {
        id: backButton
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: theme.pageSideMargin
        width: Math.min(parent.width - theme.pageSideMargin * 2,
                        Math.max(theme.textFieldWidthMedium, naturalWidth))
        compact: true
        text: "Back to Home"
        onClicked: {
            if (seekScreen.waiting) seekScreen.backendSender({type: "CancelSeek"})
            seekScreen.navigateTo("HomeScreen.qml")
        }
    }

    EinkPagedFlickable {
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

    Column {
        id: seekColumn
        width: parent.width
        spacing: theme.spacingMedium

        AppPageHeader {
            width: parent.width
            darkMode: seekScreen.darkMode
            eyebrow: "Play"
            title: "New game"
            detail: "Rapid chess on your terms"
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
                Text { text: "Minutes"; font.pixelSize: theme.fontLarge; width: parent.width - minutesField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: theme.text }
                AppTextField { id: minutesField; text: "10"; font.pixelSize: theme.fontLarge; width: theme.textFieldWidthNarrow }
            }

            Row {
                width: parent.width
                spacing: theme.spacingSmall
                Text { text: "Increment"; font.pixelSize: theme.fontLarge; width: parent.width - incrementField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: theme.text }
                AppTextField { id: incrementField; text: "0"; font.pixelSize: theme.fontLarge; width: theme.textFieldWidthNarrow }
            }
        }

        SectionCard {
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Game preferences"
            visible: !seekScreen.waiting

            Text { text: "Game type"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.text }
            Flow {
                width: parent.width
                spacing: theme.spacingXs
                AppButton { compact: true; text: "Casual"; highlighted: !seekScreen.rated; onClicked: seekScreen.rated = false }
                AppButton { compact: true; text: "Rated"; highlighted: seekScreen.rated; onClicked: seekScreen.rated = true }
            }

            Text { text: "Your color"; font.pixelSize: theme.fontLabel; font.bold: true; color: theme.text }
            Flow {
                width: parent.width
                spacing: theme.spacingXs
                AppButton { compact: true; text: "White"; highlighted: seekScreen.selectedColor === "white"; onClicked: seekScreen.selectedColor = "white" }
                AppButton { compact: true; text: "Black"; highlighted: seekScreen.selectedColor === "black"; onClicked: seekScreen.selectedColor = "black" }
                AppButton { compact: true; text: "Random"; highlighted: seekScreen.selectedColor === "random"; onClicked: seekScreen.selectedColor = "random" }
            }
        }

        AppButton {
            width: parent.width
            text: "Find an opponent"
            highlighted: true
            visible: !seekScreen.waiting
            onClicked: seekScreen.backendSender({
                type: "CreateSeek",
                minutes: parseInt(minutesField.text),
                increment: parseInt(incrementField.text),
                rated: seekScreen.rated,
                color: seekScreen.selectedColor
            })
        }

        SectionCard {
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Challenge a player"
            visible: !seekScreen.waiting
            AppTextField { id: usernameField; font.pixelSize: theme.fontLarge; placeholderText: "opponent username"; width: parent.width }
            AppButton {
                width: parent.width
                text: "Challenge"
                onClicked: seekScreen.backendSender({
                    type: "CreateChallenge",
                    username: usernameField.text,
                    minutes: parseInt(minutesField.text),
                    increment: parseInt(incrementField.text),
                    rated: seekScreen.rated,
                    color: seekScreen.selectedColor
                })
            }
        }

        AppButton {
            width: parent.width
            text: "Create a shareable challenge"
            visible: !seekScreen.waiting && seekScreen.openChallengeUrls === null
            onClicked: seekScreen.backendSender({
                type: "CreateOpenChallenge",
                minutes: parseInt(minutesField.text),
                increment: parseInt(incrementField.text),
                rated: seekScreen.rated
            })
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
            width: parent.width
            darkMode: seekScreen.darkMode
            compact: true
            title: "Play the computer"
            visible: !seekScreen.waiting
            Row {
                width: parent.width
                spacing: theme.spacingSmall
                Text { text: "Computer level (1-8)"; font.pixelSize: theme.fontLarge; width: parent.width - aiLevelField.width - parent.spacing; anchors.verticalCenter: parent.verticalCenter; color: theme.text }
                AppTextField { id: aiLevelField; text: "3"; font.pixelSize: theme.fontLarge; width: theme.textFieldWidthNarrow }
            }
            AppButton {
                width: parent.width
                text: "Start computer game"
                // Starts immediately -- no accept/decline step, so unlike the
                // seek/challenge buttons above there's no "waiting" state to enter;
                // the game arrives the same way any other game does, via the
                // account event stream's gameStart, and main.qml's router switches
                // to BoardScreen on the first BoardState like normal.
                onClicked: seekScreen.backendSender({
                    type: "ChallengeAi",
                    level: parseInt(aiLevelField.text),
                    minutes: parseInt(minutesField.text),
                    increment: parseInt(incrementField.text)
                })
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
            seekScreen.waiting = true
            seekScreen.waitingLabel = "Waiting for an opponent..."
        } else if (msg.type === "ChallengeCreated") {
            seekScreen.waiting = true
            seekScreen.waitingLabel = "Challenge sent, waiting for a reply..."
        } else if (msg.type === "OpenChallengeCreated") {
            seekScreen.openChallengeUrls = {url: msg.url, url_white: msg.url_white, url_black: msg.url_black}
        }
    }
}
