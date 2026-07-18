import QtQuick 2.5
import QtQuick.Controls 2.5
import net.asivery.AppLoad 1.0

Rectangle {
    anchors.fill: parent
    // Dark backgrounds on e-ink are a real ghosting/refresh-cost tradeoff, not a free
    // win like on an OLED phone screen (see docs/remarkable-appload-platform-notes.md).
    // Deliberately using a dark warm gray rather than pure black/white for both ends
    // of the palette, everywhere in this app, to keep the pigment shift smaller.
    color: darkMode ? "#2b2b28" : "white"

    property bool hasToken: false
    property bool darkMode: false

    function toggleDarkMode() {
        darkMode = !darkMode
    }

    // Screens are re-created fresh by the Loader on every navigation (Task 10's
    // pattern), so a plain one-time property push in onLoaded is enough for normal
    // navigation. But toggling dark mode happens *from inside* the currently loaded
    // screen (see HomeScreen's toggle button), so the already-loaded item's local
    // `darkMode` copy needs to be re-synced by hand when this changes underneath it.
    onDarkModeChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("darkMode")) {
            screenLoader.item.darkMode = darkMode
        }
    }

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
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
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

    function navigateTo(screenName) {
        screenLoader.source = screenName
    }

    Loader {
        id: screenLoader
        anchors.fill: parent
        source: "SetupScreen.qml"
        onLoaded: {
            if (item.hasOwnProperty("backendSender")) {
                item.backendSender = sendToBackend
            }
            if (item.hasOwnProperty("navigateTo")) {
                item.navigateTo = navigateTo
            }
            if (item.hasOwnProperty("darkMode")) {
                item.darkMode = darkMode
            }
            if (item.hasOwnProperty("toggleDarkMode")) {
                item.toggleDarkMode = toggleDarkMode
            }
        }
    }
}
