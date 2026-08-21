import QtQuick 2.5

Rectangle {
    id: gameHistoryScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: gameHistoryScreen.darkMode }
    ChessDisplay { id: chessDisplay }
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
    property bool loading: true

    onBackendSenderChanged: {
        if (gameHistoryScreen.backendSender) gameHistoryScreen.requestFiltered()
    }

    function requestFiltered() {
        gameHistoryScreen.loading = true
        gameHistoryScreen.errorMessage = ""
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

    Column {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        spacing: theme.spacingSmall

        AppPageHeader {
            width: parent.width
            darkMode: gameHistoryScreen.darkMode
            eyebrow: "Archive"
            title: "Game history"
            detail: gameHistoryScreen.loading
                ? "Loading your games"
                : (gameHistoryScreen.games.length + " recent games")
        }

        SectionCard {
            width: parent.width
            darkMode: gameHistoryScreen.darkMode
            compact: true
            title: "Filters"

            Text { text: "Game type"; font.pixelSize: theme.fontEyebrow; font.bold: true; color: theme.textMuted }
            Flow {
                width: parent.width
                spacing: theme.spacingXs
                Repeater {
                    model: ["all", "rated", "casual"]
                    AppButton {
                        required property string modelData
                        compact: true
                        text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                        highlighted: gameHistoryScreen.filterRated === modelData
                        onClicked: {
                            gameHistoryScreen.filterRated = modelData
                            gameHistoryScreen.requestFiltered()
                        }
                    }
                }
            }

            Text { text: "Speed"; font.pixelSize: theme.fontEyebrow; font.bold: true; color: theme.textMuted }
            Flow {
                width: parent.width
                spacing: theme.spacingXs
                Repeater {
                    model: ["all", "bullet", "blitz", "rapid", "classical", "correspondence"]
                    AppButton {
                        required property string modelData
                        compact: true
                        text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                        highlighted: gameHistoryScreen.filterSpeed === modelData
                        onClicked: {
                            gameHistoryScreen.filterSpeed = modelData
                            gameHistoryScreen.requestFiltered()
                        }
                    }
                }
            }

            Text { text: "Side"; font.pixelSize: theme.fontEyebrow; font.bold: true; color: theme.textMuted }
            Flow {
                width: parent.width
                spacing: theme.spacingXs
                Repeater {
                    model: ["all", "white", "black"]
                    AppButton {
                        required property string modelData
                        compact: true
                        text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                        highlighted: gameHistoryScreen.filterColor === modelData
                        onClicked: {
                            gameHistoryScreen.filterColor = modelData
                            gameHistoryScreen.requestFiltered()
                        }
                    }
                }
            }
        }

        Text {
            visible: gameHistoryScreen.loading || gameHistoryScreen.games.length === 0
            text: gameHistoryScreen.loading ? "Loading games..." : "No games match these filters."
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

    AppButton {
        id: backButton
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: theme.pageSideMargin
        width: Math.min(parent.width - theme.pageSideMargin * 2,
                        Math.max(theme.textFieldWidthMedium, naturalWidth))
        compact: true
        text: "Back to Home"
        onClicked: gameHistoryScreen.navigateTo("HomeScreen.qml")
    }

    EinkPagedFlickable {
        id: historyList
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
        contentHeight: historyColumn.height

        Column {
            id: historyColumn
            width: parent.width
            spacing: theme.spacingSmall

            Repeater {
                model: gameHistoryScreen.games

                Rectangle {
                required property var modelData
                width: parent.width
                // Never thinner than the shared list-row touch floor, however
                // little text a row happens to have.
                height: Math.max(rowContent.height + theme.spacingMedium, theme.listRowHeight)
                color: theme.cardBackground
                border.width: 1
                border.color: theme.cardBorder
                radius: theme.cardRadius

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: theme.sectionRailWidth
                    color: gameHistoryScreen.resultColor(modelData.result)
                }

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
                    anchors.leftMargin: theme.spacingSmall + theme.sectionRailWidth
                    anchors.rightMargin: theme.spacingXs
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.spacingXs

                    Row {
                        spacing: theme.spacingXs
                        Text {
                            text: chessDisplay.resultLabel(modelData.result)
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
                              (modelData.speed ? " · " + chessDisplay.speedLabel(modelData.speed) : "") +
                              (modelData.termination ? " · " + chessDisplay.terminationLabel(modelData.termination) : "") +
                              (modelData.opening_name ? " · " + modelData.opening_name : "") +
                              (modelData.created_at_ms ? " · " + new Date(modelData.created_at_ms).toLocaleDateString() : "")
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
                              " · " + modelData.your_analysis.blunders + " blunders, " +
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
        }
    }

    function handleMessage(msg) {
        if (msg.type === "GameHistory") {
            gameHistoryScreen.loading = false
            gameHistoryScreen.games = msg.games || []
        } else if (msg.type === "ErrorMsg") {
            gameHistoryScreen.loading = false
            gameHistoryScreen.errorMessage = msg.message
        }
    }
}
