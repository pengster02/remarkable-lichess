import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: gameHistoryScreen
    anchors.fill: parent
    color: gameHistoryScreen.darkMode ? "#2b2b28" : "white"
    property var backendSender
    property var navigateTo
    property bool darkMode: false
    // Populated by HomeScreen's "Game history" button sending RequestGameHistory
    // right before navigating here (see protocol.rs's RequestGameHistory) --
    // this screen doesn't request it itself in Component.onCompleted, since
    // backendSender isn't guaranteed assigned yet at that point (see main.qml's
    // Loader.onLoaded, which runs after the item is constructed).
    property var games: []
    // "all"/"rated"/"casual" -- "all" sends rated: null, matching GET
    // /api/games/user's own default of no rated/casual filter at all.
    property string filterRated: "all"
    // "all"/"bullet"/"blitz"/"rapid"/"classical"/"correspondence" -- maps to
    // that endpoint's own `perfType` query param (see protocol.rs's
    // RequestGameHistory `speed` field / backend_app.rs's GameHistoryFilters).
    property string filterSpeed: "all"
    // "all"/"white"/"black" -- that endpoint's own `color` query param.
    property string filterColor: "all"

    function requestFiltered() {
        gameHistoryScreen.backendSender({
            type: "RequestGameHistory",
            rated: gameHistoryScreen.filterRated === "all" ? null : gameHistoryScreen.filterRated === "rated",
            speed: gameHistoryScreen.filterSpeed === "all" ? null : gameHistoryScreen.filterSpeed,
            color: gameHistoryScreen.filterColor === "all" ? null : gameHistoryScreen.filterColor
        })
    }

    function resultColor(result) {
        if (result === "win") return gameHistoryScreen.darkMode ? "#8fc98f" : "#2e7d32"
        if (result === "loss") return gameHistoryScreen.darkMode ? "#e08a8a" : "#a03030"
        return gameHistoryScreen.darkMode ? "#c8c4b8" : "#555550"
    }

    function resultLabel(result) {
        if (result === "win") return "Win"
        if (result === "loss") return "Loss"
        if (result === "draw") return "Draw"
        return result.charAt(0).toUpperCase() + result.slice(1)
    }

    Column {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 16
        anchors.topMargin: 72
        spacing: 12

        Text {
            text: "Game history"
            font.pixelSize: 36
            color: gameHistoryScreen.darkMode ? "#e6e2d8" : "black"
        }

        Flow {
            width: parent.width
            spacing: 6
            Repeater {
                model: ["all", "rated", "casual"]
                Button {
                    required property string modelData
                    text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                    highlighted: gameHistoryScreen.filterRated === modelData
                    onClicked: {
                        gameHistoryScreen.filterRated = modelData
                        gameHistoryScreen.requestFiltered()
                    }
                }
            }
        }

        Flow {
            width: parent.width
            spacing: 6
            Repeater {
                model: ["all", "bullet", "blitz", "rapid", "classical", "correspondence"]
                Button {
                    required property string modelData
                    text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                    highlighted: gameHistoryScreen.filterSpeed === modelData
                    onClicked: {
                        gameHistoryScreen.filterSpeed = modelData
                        gameHistoryScreen.requestFiltered()
                    }
                }
            }
        }

        Flow {
            width: parent.width
            spacing: 6
            Repeater {
                model: ["all", "white", "black"]
                Button {
                    required property string modelData
                    text: "Played " + modelData.charAt(0).toUpperCase() + modelData.slice(1)
                    highlighted: gameHistoryScreen.filterColor === modelData
                    onClicked: {
                        gameHistoryScreen.filterColor = modelData
                        gameHistoryScreen.requestFiltered()
                    }
                }
            }
        }

        Text {
            visible: gameHistoryScreen.games.length === 0
            text: "No games match these filters."
            font.pixelSize: 20
            color: gameHistoryScreen.darkMode ? "#e6e2d8" : "black"
        }
    }

    Button {
        id: backButton
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.margins: 16
        text: "Back to Home"
        onClicked: gameHistoryScreen.navigateTo("HomeScreen.qml")
    }

    ListView {
        // Anchored between the filter header and the Back button instead of a
        // fixed "parent.height - N" offset -- the filter Flows above can wrap to
        // an extra line depending on content width, which a magic-number height
        // wouldn't account for.
        anchors.top: header.bottom
        anchors.topMargin: 12
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: backButton.top
        anchors.margins: 16
        anchors.bottomMargin: 12
        // No rubber-band overshoot at the ends -- that bounce is a multi-frame
        // animation, which on e-ink is a real cost (each frame is a partial
        // refresh) for a purely cosmetic effect with no equivalent value here.
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        spacing: 10
        model: gameHistoryScreen.games
        delegate: Rectangle {
                required property var modelData
                width: gameHistoryScreen.width - 32
                height: rowContent.height + 16
                color: gameHistoryScreen.darkMode ? "#3a382e" : "#f2ede0"
                border.width: 1
                border.color: gameHistoryScreen.darkMode ? "#5a5a55" : "#8a7f6a"
                radius: 4

                Column {
                    id: rowContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 8
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Row {
                        spacing: 8
                        Text {
                            text: gameHistoryScreen.resultLabel(modelData.result)
                            font.pixelSize: 20
                            font.bold: true
                            color: gameHistoryScreen.resultColor(modelData.result)
                        }
                        Text {
                            text: "vs " + (modelData.opponent_name || "Opponent") +
                                  (modelData.opponent_rating ? " (" + modelData.opponent_rating + ")" : "")
                            font.pixelSize: 20
                            color: gameHistoryScreen.darkMode ? "#e6e2d8" : "black"
                        }
                    }

                    Text {
                        text: (modelData.rated ? "Rated" : "Casual") +
                              (modelData.speed ? " " + modelData.speed : "") +
                              (modelData.opening_name ? " -- " + modelData.opening_name : "") +
                              (modelData.created_at_ms ? " -- " + new Date(modelData.created_at_ms).toLocaleDateString() : "")
                        font.pixelSize: 15
                        wrapMode: Text.WordWrap
                        width: rowContent.width
                        color: gameHistoryScreen.darkMode ? "#c8c4b8" : "#555550"
                    }
                }
            }
        }

    function handleMessage(msg) {
        if (msg.type === "GameHistory") {
            gameHistoryScreen.games = msg.games || []
        }
    }
}
