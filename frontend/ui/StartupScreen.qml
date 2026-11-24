import QtQuick 2.5

Rectangle {
    id: startupScreen
    anchors.fill: parent
    color: theme.background
    property bool darkMode: false
    property var backendSender
    property var showSignIn
    property string checkError: ""

    Theme { id: theme; darkMode: startupScreen.darkMode }

    Column {
        anchors.centerIn: parent
        width: parent.width * 0.72
        spacing: theme.spacingMedium

        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 180
            height: 180
            source: "../assets/pieces/cburnett/wK.png"
            fillMode: Image.PreserveAspectFit
            smooth: false
            sourceSize.width: width
            sourceSize.height: height
        }

        Text {
            objectName: "startupTitle"
            width: parent.width
            text: "Opening your board"
            font.pixelSize: theme.fontHeading
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: theme.text
        }

        Text {
            objectName: "startupStatus"
            width: parent.width
            text: startupScreen.checkError || "Checking your saved Lichess sign-in…"
            font.pixelSize: theme.fontBody
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            color: theme.textMuted
        }

        AppButton {
            objectName: "retryAuthenticationButton"
            anchors.horizontalCenter: parent.horizontalCenter
            visible: startupScreen.checkError.length > 0
            text: "Try again"
            highlighted: true
            onClicked: {
                startupScreen.checkError = ""
                startupScreen.backendSender({type: "RetryAuthentication"})
            }
        }

        AppButton {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: startupScreen.checkError.length > 0
            text: "Use a different sign-in"
            onClicked: startupScreen.showSignIn()
        }
    }

    function handleMessage(msg) {
        if (msg.type === "AuthenticationCheckFailed") startupScreen.checkError = msg.message
    }
}
