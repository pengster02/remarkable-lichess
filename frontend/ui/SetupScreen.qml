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

        Text {
            text: "Enter your Lichess personal API token"
            font.pixelSize: 32
            wrapMode: Text.WordWrap
            width: parent.width
        }

        TextField {
            id: tokenField
            width: parent.width
            font.pixelSize: 28
            placeholderText: "lip_..."
        }

        Text {
            id: errorText
            color: "black"
            font.pixelSize: 24
            visible: text.length > 0
        }

        Button {
            text: "Save"
            onClicked: {
                errorText.text = ""
                backendSender({type: "SaveToken", token: tokenField.text})
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "TokenInvalid") {
            errorText.text = "Token rejected: " + msg.reason
        }
    }
}
