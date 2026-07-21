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

        Button {
            text: "Open seek (auto-pair)"
            visible: !seekScreen.waiting
            onClicked: seekScreen.backendSender({
                type: "CreateSeek",
                minutes: parseInt(minutesField.text),
                increment: parseInt(incrementField.text)
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
        }
    }
}
