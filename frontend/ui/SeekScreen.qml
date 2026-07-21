import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: seekScreen
    anchors.fill: parent
    color: seekScreen.darkMode ? "#2b2b28" : "white"
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

    Column {
        anchors.centerIn: parent
        spacing: 24
        width: parent.width * 0.8

        Text { text: "New rapid game"; font.pixelSize: 40; color: seekScreen.darkMode ? "#e6e2d8" : "black" }

        Row {
            spacing: 16
            visible: !seekScreen.waiting
            Text { text: "Minutes:"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter; color: seekScreen.darkMode ? "#e6e2d8" : "black" }
            TextField { id: minutesField; text: "10"; font.pixelSize: 24; width: 80 }
            Text { text: "Increment:"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter; color: seekScreen.darkMode ? "#e6e2d8" : "black" }
            TextField { id: incrementField; text: "0"; font.pixelSize: 24; width: 80 }
        }

        CheckBox {
            text: "Rated"
            visible: !seekScreen.waiting
            checked: seekScreen.rated
            onCheckedChanged: seekScreen.rated = checked
        }

        Flow {
            width: parent.width
            spacing: 8
            visible: !seekScreen.waiting
            Text { text: "Color:"; font.pixelSize: 24; color: seekScreen.darkMode ? "#e6e2d8" : "black" }
            Button { text: "White"; highlighted: seekScreen.selectedColor === "white"; onClicked: seekScreen.selectedColor = "white" }
            Button { text: "Black"; highlighted: seekScreen.selectedColor === "black"; onClicked: seekScreen.selectedColor = "black" }
            Button { text: "Random"; highlighted: seekScreen.selectedColor === "random"; onClicked: seekScreen.selectedColor = "random" }
        }

        Button {
            text: "Open seek (auto-pair)"
            visible: !seekScreen.waiting
            onClicked: seekScreen.backendSender({
                type: "CreateSeek",
                minutes: parseInt(minutesField.text),
                increment: parseInt(incrementField.text),
                rated: seekScreen.rated,
                color: seekScreen.selectedColor
            })
        }

        Row {
            spacing: 16
            visible: !seekScreen.waiting
            TextField { id: usernameField; font.pixelSize: 24; placeholderText: "opponent username"; width: 240 }
            Button {
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

        Button {
            text: "Create open challenge link"
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
            spacing: 8

            Text {
                text: "Share one of these links -- whoever opens it starts the game:"
                font.pixelSize: 18
                wrapMode: Text.WordWrap
                width: parent.width
                color: seekScreen.darkMode ? "#e6e2d8" : "black"
            }
            TextEdit {
                readOnly: true
                selectByMouse: true
                width: parent.width
                wrapMode: Text.WrapAnywhere
                font.pixelSize: 16
                color: seekScreen.darkMode ? "#e6e2d8" : "black"
                text: "White: " + (seekScreen.openChallengeUrls ? seekScreen.openChallengeUrls.url_white : "")
            }
            TextEdit {
                readOnly: true
                selectByMouse: true
                width: parent.width
                wrapMode: Text.WrapAnywhere
                font.pixelSize: 16
                color: seekScreen.darkMode ? "#e6e2d8" : "black"
                text: "Black: " + (seekScreen.openChallengeUrls ? seekScreen.openChallengeUrls.url_black : "")
            }
        }

        Row {
            spacing: 16
            visible: !seekScreen.waiting
            Text { text: "Level (1-8):"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter; color: seekScreen.darkMode ? "#e6e2d8" : "black" }
            TextField { id: aiLevelField; text: "3"; font.pixelSize: 24; width: 60 }
            Button {
                text: "Play vs Computer"
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
            font.pixelSize: 24
            color: seekScreen.darkMode ? "#e6e2d8" : "black"
        }

        Button {
            text: "Cancel"
            visible: seekScreen.waiting
            onClicked: {
                seekScreen.backendSender({type: "CancelSeek"})
                seekScreen.waiting = false
            }
        }

        Button {
            text: "Back to Home"
            onClicked: {
                if (seekScreen.waiting) seekScreen.backendSender({type: "CancelSeek"})
                seekScreen.navigateTo("HomeScreen.qml")
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
