import QtQuick 2.5
import net.asivery.AppLoad 1.0

Rectangle {
    id: root
    anchors.fill: parent
    // Dark backgrounds on e-ink are a real ghosting/refresh-cost tradeoff, not a free
    // win like on an OLED phone screen (see docs/remarkable-appload-platform-notes.md).
    // Deliberately using a dark warm gray rather than pure black/white for both ends
    // of the palette, everywhere in this app, to keep the pigment shift smaller.
    color: root.darkMode ? "#2b2b28" : "white"

    property bool hasToken: false
    property bool darkMode: false

    function toggleDarkMode() {
        root.darkMode = !root.darkMode
    }

    // Screens are re-created fresh by the Loader on every navigation (Task 10's
    // pattern), so a plain one-time property push in onLoaded is enough for normal
    // navigation. But toggling dark mode happens *from inside* the currently loaded
    // screen (see HomeScreen's toggle button), so the already-loaded item's local
    // `darkMode` copy needs to be re-synced by hand when this changes underneath it.
    onDarkModeChanged: {
        if (screenLoader.item && screenLoader.item.hasOwnProperty("darkMode")) {
            screenLoader.item.darkMode = root.darkMode
        }
    }

    // Required by the AppLoad host: it looks up `close`/`unloading` on the
    // root QML item (see rmpp-appload's window.qml Connections/onUnloading
    // wiring). `close` lets the app request that AppLoad tear down its
    // window; `unloading` is invoked right before AppLoad unloads this
    // frontend so it can release any resources.
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
                root.hasToken = true
                endpoint.sendMessage(1, JSON.stringify({type: "RequestHome"}))
                endpoint.sendMessage(1, JSON.stringify({type: "RequestChallenges"}))
                screenLoader.source = "HomeScreen.qml"
            } else if (msg.type === "TokenInvalid") {
                root.hasToken = false
                screenLoader.source = "SetupScreen.qml"
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "HomeState" || msg.type === "SeekCreated" || msg.type === "ChallengeCreated" || msg.type === "PendingChallenges") {
                if (screenLoader.item && screenLoader.item.handleMessage) {
                    screenLoader.item.handleMessage(msg)
                }
            } else if (msg.type === "BoardState" || msg.type === "GameOver" || msg.type === "MoveRejected") {
                // Never force-navigate away from Home: a user who explicitly went
                // back to Home (or never left it yet) should stay there even if a
                // still-running per-game stream keeps delivering messages -- this
                // was the root cause of "Back to Home doesn't work" (confirmed via
                // the PC emulator: any lingering game message snapped the screen
                // back to Board with no way out). Every other screen (Setup, Seek,
                // Board itself) still auto-advances to Board normally, since that's
                // the desired flow for a freshly-started/still-loading game.
                if (screenLoader.source.toString().indexOf("HomeScreen") === -1) {
                    if (screenLoader.source.toString().indexOf("BoardScreen") === -1) {
                        screenLoader.source = "BoardScreen.qml"
                    }
                    if (screenLoader.item && screenLoader.item.handleMessage) {
                        screenLoader.item.handleMessage(msg)
                    }
                }
            } else if (msg.type === "Reconnecting" || msg.type === "OpponentGone" || msg.type === "ChatMessage") {
                // Deliberately never navigates on its own (confirmed via the PC
                // emulator: a bare Reconnecting with no real game yet threw the
                // user onto a genuinely empty, un-escapable Board screen). Only
                // ever forwarded to whichever screen is already showing.
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
                item.backendSender = root.sendToBackend
            }
            if (item.hasOwnProperty("navigateTo")) {
                item.navigateTo = root.navigateTo
            }
            if (item.hasOwnProperty("darkMode")) {
                item.darkMode = root.darkMode
            }
            if (item.hasOwnProperty("toggleDarkMode")) {
                item.toggleDarkMode = root.toggleDarkMode
            }
        }
    }

    // Visible exit affordance on every screen, on top of the Loader. The host
    // already provides a swipe-down-from-top-edge -> "X" close mechanism for
    // any fullscreen AppLoad app (see docs/remarkable-appload-platform-notes.md),
    // but it's easy to miss -- this just makes the same `close()` signal
    // reachable with one direct tap instead.
    Rectangle {
        id: exitButton
        width: 48
        height: 48
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.margins: 12
        z: 1000
        radius: 4
        color: root.darkMode ? "#3a3a36" : "#e8e0d0"
        border.width: 1
        border.color: root.darkMode ? "#5a5a55" : "#8a7f6a"

        Text {
            anchors.centerIn: parent
            text: "X"
            font.pixelSize: 22
            color: root.darkMode ? "white" : "black"
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }
}
