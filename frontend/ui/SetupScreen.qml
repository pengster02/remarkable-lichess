import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: setupScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: setupScreen.darkMode }
    property var backendSender
    property bool darkMode: false

    Column {
        // Top-anchored (was `anchors.centerIn: parent`) for the same
        // cross-page alignment reason as every other screen in this pass --
        // this is most people's very first screen, so it's the single most
        // important one to already look consistent with the rest of the app.
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: theme.pageTopMargin
        spacing: theme.spacingMedium
        width: parent.width * 0.85

        Column {
            spacing: theme.spacingSmall
            anchors.horizontalCenter: parent.horizontalCenter
            Image {
                anchors.horizontalCenter: parent.horizontalCenter
                source: "../assets/pieces/wK.png"
                width: 150
                height: 150
                fillMode: Image.PreserveAspectFit
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Lichess"
                font.pixelSize: theme.fontDisplay
                font.bold: true
                color: theme.text
            }
        }

        SectionCard {
            darkMode: setupScreen.darkMode
            title: "Sign in with a personal access token"
            width: parent.width

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Generate one at lichess.org/account/oauth/token with the board:play, challenge:read, challenge:write, and preference:read scopes, then paste it below."
                font.pixelSize: theme.fontSmall
                color: theme.textMuted
            }

            TextField {
                id: tokenField
                width: parent.width
                font.pixelSize: theme.fontLarge
                placeholderText: "lip_..."
            }

            Text {
                id: errorText
                width: parent.width
                wrapMode: Text.WordWrap
                color: theme.errorText
                font.pixelSize: theme.fontLabel
                visible: text.length > 0
            }

            Button {
                text: "Save"
                onClicked: {
                    errorText.text = ""
                    setupScreen.backendSender({type: "SaveToken", token: tokenField.text})
                }
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "TokenInvalid") {
            errorText.text = "Token rejected: " + msg.reason
        }
    }
}
