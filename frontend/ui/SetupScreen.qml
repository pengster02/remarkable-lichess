import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: setupScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: setupScreen.darkMode }
    property var backendSender
    property bool darkMode: false

    Flickable {
        // Wrapped in a Flickable (was a bare top-anchored Column) -- this
        // screen's own Save button alone is now ~430px tall (buttonPaddingV
        // 170*2 + buttonMinHeight 320 floor), and stacked under the logo,
        // heading, description text, and token field it doesn't reliably fit
        // this device's 954px-tall screen even with the top margin alone
        // eating ~148px of that budget. A bare Column has no scrolling at
        // all, so an overflow here means the Save button is simply
        // unreachable -- on a new user's very first screen. Same pattern
        // every other screen already uses (see SeekScreen/SettingsScreen).
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        contentWidth: width
        contentHeight: setupColumn.height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

    Column {
        id: setupColumn
        anchors.horizontalCenter: parent.horizontalCenter
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

            AppTextField {
                id: tokenField
                width: parent.width
                font.pixelSize: theme.fontLarge
                placeholderText: "lip_..."
                Keys.onReturnPressed: saveToken()
                Keys.onEnterPressed: saveToken()
            }

            Text {
                id: errorText
                width: parent.width
                wrapMode: Text.WordWrap
                color: theme.errorText
                font.pixelSize: theme.fontLabel
                visible: text.length > 0
            }

            AppButton {
                width: parent.width
                text: "Save"
                highlighted: true
                onClicked: saveToken()
            }
        }
    }
    }

    function saveToken() {
        errorText.text = ""
        setupScreen.backendSender({type: "SaveToken", token: tokenField.text})
    }

    function handleMessage(msg) {
        if (msg.type === "TokenInvalid") {
            errorText.text = "Token rejected: " + msg.reason
        }
    }
}
