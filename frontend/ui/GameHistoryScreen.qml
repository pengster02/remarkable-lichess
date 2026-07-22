import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: gameHistoryScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: gameHistoryScreen.darkMode }
    property var backendSender
    property var navigateTo
    property bool darkMode: false
    // Pushed in by main.qml (see its own selectGameForReview) -- sends
    // RequestGameMoves *and* remembers the tapped row's own summary so
    // GameReviewScreen's header can show who was played, not just moves/fens.
    property var selectGameForReview
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
    // Set when a tapped game's RequestGameMoves comes back as ErrorMsg instead
    // of GameMoves (see main.qml, which only navigates to GameReviewScreen on
    // the latter) -- so a bad export/replay leaves the user on this screen
    // with a visible reason instead of silently doing nothing.
    property string errorMessage: ""

    function requestFiltered() {
        gameHistoryScreen.backendSender({
            type: "RequestGameHistory",
            rated: gameHistoryScreen.filterRated === "all" ? null : gameHistoryScreen.filterRated === "rated",
            speed: gameHistoryScreen.filterSpeed === "all" ? null : gameHistoryScreen.filterSpeed,
            color: gameHistoryScreen.filterColor === "all" ? null : gameHistoryScreen.filterColor
        })
    }

    function resultColor(result) {
        if (result === "win") return theme.winText
        if (result === "loss") return theme.lossText
        return theme.drawText
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
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        spacing: theme.spacingSmall

        Text {
            text: "Game history"
            font.pixelSize: theme.fontHeading
            color: theme.text
        }

        Flow {
            width: parent.width
            spacing: theme.spacingSmall
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
            spacing: theme.spacingSmall
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
            spacing: theme.spacingSmall
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
            font.pixelSize: theme.fontBody
            color: theme.text
        }

        Text {
            visible: gameHistoryScreen.errorMessage.length > 0
            text: gameHistoryScreen.errorMessage
            font.pixelSize: theme.fontBody
            color: theme.errorText
            wrapMode: Text.WordWrap
            width: parent.width
        }
    }

    Button {
        id: backButton
        // Bottom, full-width, same fixed-position "nav bar" treatment on
        // every screen that has a back action (see GameReviewScreen,
        // SettingsScreen, SeekScreen, BoardScreen) rather than each screen
        // burying it wherever its own content column happened to end.
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        text: "Back to Home"
        onClicked: gameHistoryScreen.navigateTo("HomeScreen.qml")
    }

    ListView {
        // Anchored between the filter header and the Back button instead of a
        // fixed "parent.height - N" offset -- the filter Flows above can wrap to
        // an extra line depending on content width, which a magic-number height
        // wouldn't account for.
        anchors.top: header.bottom
        anchors.topMargin: theme.spacingSmall
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: backButton.top
        anchors.margins: theme.pageSideMargin
        anchors.bottomMargin: theme.spacingSmall
        // No rubber-band overshoot at the ends -- that bounce is a multi-frame
        // animation, which on e-ink is a real cost (each frame is a partial
        // refresh) for a purely cosmetic effect with no equivalent value here.
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        spacing: theme.spacingSmall
        model: gameHistoryScreen.games
        delegate: Rectangle {
                required property var modelData
                width: gameHistoryScreen.width - theme.pageSideMargin * 2
                height: rowContent.height + theme.spacingMedium
                color: theme.cardBackground
                border.width: 1
                border.color: theme.cardBorder
                radius: theme.cardRadius

                // Opens GameReviewScreen once the reply lands -- see main.qml's
                // GameMoves handler. Not an immediate navigation: staying here
                // until the reply arrives is what lets an ErrorMsg reply (bad
                // export/replay) show inline instead of landing on a broken
                // review screen (see the game-review design spec's error
                // handling section).
                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        gameHistoryScreen.errorMessage = ""
                        gameHistoryScreen.selectGameForReview(modelData)
                    }
                }

                Column {
                    id: rowContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: theme.spacingXs
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.spacingXs

                    Row {
                        spacing: theme.spacingXs
                        Text {
                            text: gameHistoryScreen.resultLabel(modelData.result)
                            font.pixelSize: theme.fontBody
                            font.bold: true
                            color: gameHistoryScreen.resultColor(modelData.result)
                        }
                        // Your own rating change from this one game (rated games
                        // only -- Lichess never sends this for a casual game) --
                        // same "+8"/"-12" convention Lichess's own game list uses.
                        Text {
                            visible: modelData.rating_diff !== null && modelData.rating_diff !== undefined
                            text: modelData.rating_diff > 0 ? ("+" + modelData.rating_diff) : ("" + modelData.rating_diff)
                            font.pixelSize: theme.fontBody
                            color: modelData.rating_diff > 0 ? theme.winText : theme.lossText
                        }
                        Text {
                            text: "vs " + (modelData.opponent_name || "Opponent") +
                                  (modelData.opponent_rating ? " (" + modelData.opponent_rating + ")" : "")
                            font.pixelSize: theme.fontBody
                            color: theme.text
                        }
                    }

                    Text {
                        text: (modelData.rated ? "Rated" : "Casual") +
                              (modelData.speed ? " " + modelData.speed : "") +
                              (modelData.termination ? " -- " + modelData.termination : "") +
                              (modelData.opening_name ? " -- " + modelData.opening_name : "") +
                              (modelData.created_at_ms ? " -- " + new Date(modelData.created_at_ms).toLocaleDateString() : "")
                        font.pixelSize: theme.fontSmall
                        wrapMode: Text.WordWrap
                        width: rowContent.width
                        color: theme.textMuted
                    }

                    // Only present once this specific game has been through
                    // Lichess's computer analysis (most never are) -- same
                    // your_analysis field GameReviewScreen's own header shows.
                    Text {
                        visible: modelData.your_analysis
                        text: modelData.your_analysis
                            ? "Accuracy " +
                              (modelData.your_analysis.accuracy !== null && modelData.your_analysis.accuracy !== undefined
                                  ? modelData.your_analysis.accuracy + "%"
                                  : "n/a") +
                              " -- " + modelData.your_analysis.blunders + " blunders, " +
                              modelData.your_analysis.mistakes + " mistakes"
                            : ""
                        font.pixelSize: theme.fontSmall
                        wrapMode: Text.WordWrap
                        width: rowContent.width
                        color: theme.textMuted
                    }
                }
            }
        }

    function handleMessage(msg) {
        if (msg.type === "GameHistory") {
            gameHistoryScreen.games = msg.games || []
        } else if (msg.type === "ErrorMsg") {
            gameHistoryScreen.errorMessage = msg.message
        }
    }
}
