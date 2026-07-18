import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    anchors.fill: parent
    color: "white"
    property var backendSender
    property var navigateTo
    property string resumableGameId: ""

    Column {
        anchors.centerIn: parent
        spacing: 24

        Text {
            text: "Lichess"
            font.pixelSize: 48
        }

        Button {
            text: "Resume game"
            visible: resumableGameId.length > 0
            onClicked: {
                // There is no "resume" FrontendMessage: the per-game stream (Task 9) is
                // already running server-side and will emit BoardState on its own, and
                // main.qml's router (Task 10) auto-switches to BoardScreen.qml on the
                // first BoardState/GameOver/etc. regardless. We still navigate here for
                // an immediate UI transition instead of leaving Home showing while the
                // first BoardState is in flight.
                navigateTo("BoardScreen.qml")
            }
        }

        Button {
            text: "New game"
            onClicked: {
                navigateTo("SeekScreen.qml")
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "HomeState") {
            resumableGameId = msg.resumable_game_id || ""
        }
    }
}
