import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    anchors.fill: parent
    color: "white"
    property var backendSender

    Column {
        anchors.centerIn: parent
        spacing: 24
        width: parent.width * 0.8

        Text { text: "New rapid game"; font.pixelSize: 40 }

        Row {
            spacing: 16
            Text { text: "Minutes:"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter }
            TextField { id: minutesField; text: "10"; font.pixelSize: 24; width: 80 }
            Text { text: "Increment:"; font.pixelSize: 24; anchors.verticalCenter: parent.verticalCenter }
            TextField { id: incrementField; text: "0"; font.pixelSize: 24; width: 80 }
        }

        Button {
            text: "Open seek (auto-pair)"
            onClicked: backendSender({
                type: "CreateSeek",
                minutes: parseInt(minutesField.text),
                increment: parseInt(incrementField.text)
            })
        }

        Row {
            spacing: 16
            TextField { id: usernameField; font.pixelSize: 24; placeholderText: "opponent username"; width: 240 }
            Button {
                text: "Challenge"
                onClicked: backendSender({
                    type: "CreateChallenge",
                    username: usernameField.text,
                    minutes: parseInt(minutesField.text),
                    increment: parseInt(incrementField.text)
                })
            }
        }
    }

    function handleMessage(msg) {
        // SeekCreated / ChallengeCreated are informational only in v1 — the actual
        // transition to BoardScreen happens when main.qml's router (Task 10) sees the
        // first BoardState message arrive from the background game stream (Task 9).
    }
}
