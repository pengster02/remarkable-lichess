import QtQuick 2.5
import QtQuick.Controls 2.5
import net.asivery.AppLoad 1.0

Rectangle {
    anchors.fill: parent
    color: "white"

    property bool hasToken: false

    // Required by the AppLoad host: it looks up `close`/`unloading` on the
    // root QML item (see rmpp-appload's window.qml Connections/onUnloading
    // wiring). `close` lets the app request that AppLoad tear down its
    // window; `unloading` is invoked right before AppLoad unloads this
    // frontend so it can release any resources. Neither is used yet, but
    // both must exist for the host contract to be satisfied.
    signal close
    function unloading() {
        // Nothing to release; the backend session ends when AppLoad kills
        // the backend process independently of this frontend.
    }

    AppLoad {
        id: endpoint
        applicationID: "remarkable-lichess"
        onMessageReceived: (type, contents) => {
            var msg = JSON.parse(contents)
            if (msg.type === "TokenVerified") {
                hasToken = true
                endpoint.sendMessage(1, JSON.stringify({type: "RequestHome"}))
                screenLoader.source = "HomeScreen.qml"
            } else if (msg.type === "TokenInvalid") {
                hasToken = false
                screenLoader.source = "SetupScreen.qml"
            } else if (msg.type === "HomeState" || msg.type === "SeekCreated" || msg.type === "ChallengeCreated") {
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "BoardState" || msg.type === "GameOver" || msg.type === "MoveRejected" || msg.type === "Reconnecting") {
                if (screenLoader.source.toString().indexOf("BoardScreen") === -1) {
                    screenLoader.source = "BoardScreen.qml"
                }
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "ErrorMsg") {
                console.warn("Backend error: " + msg.message)
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            }
        }
    }

    function sendToBackend(obj) {
        endpoint.sendMessage(1, JSON.stringify(obj))
    }

    Loader {
        id: screenLoader
        anchors.fill: parent
        source: "SetupScreen.qml"
        onLoaded: {
            if (item.hasOwnProperty("backendSender")) {
                item.backendSender = sendToBackend
            }
        }
    }
}
