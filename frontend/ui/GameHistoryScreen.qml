import QtQuick 2.9

Rectangle {
    id: gameHistoryScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: gameHistoryScreen.darkMode }
    ChessDisplay { id: chessDisplay }
    property var backendSender
    property var nextRequestId
    property var navigateTo
    property bool darkMode: false
    // Pushed in by main.qml (see its own selectGameForReview) -- sends
    // RequestGameMoves *and* remembers the tapped row's own summary so
    // GameReviewScreen's header can show who was played, not just moves/fens.
    property var selectGameForReview
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
    property string errorMessage: ""
    property string loadError: ""
    property string olderLoadError: ""
    property var nextHistoryCursor: null
    property int pendingHistoryRequest: 0
    property bool loading: true
    readonly property bool loadingOlder: pendingHistoryRequest > 0 && !loading
    property bool openingReview: false
    property bool showFilters: false
    property string draftRated: "all"
    property string draftSpeed: "all"
    property string draftColor: "all"
    property var restoredPosition: null

    onBackendSenderChanged: if (loading) requestFiltered()
    onNextRequestIdChanged: if (loading) requestFiltered()
    Component.onDestruction: {
        if (gameHistoryScreen.pendingHistoryRequest > 0 && gameHistoryScreen.backendSender) {
            gameHistoryScreen.backendSender({type: "CancelGameHistory",
                                             request_id: gameHistoryScreen.pendingHistoryRequest})
        }
    }

    function captureHistoryPosition() {
        if (historyList.contentY > 0) {
            historyColumn.forceLayout()
            for (var index = 0; index < historyRows.count; index++) {
                var row = historyRows.itemAt(index)
                if (row && row.y + row.height > historyList.contentY) {
                    return {index: index, inset: historyList.contentY - row.y}
                }
            }
        }
        return null
    }

    function captureHistoryVisit() {
        // Keep the loaded visit and a row-relative position. Refetching can reorder
        // the list, and keeping the whole screen alive leaves its UI mounted.
        return {
            filterRated: filterRated,
            filterSpeed: filterSpeed,
            filterColor: filterColor,
            games: games,
            loading: loading,
            loadError: loadError,
            olderLoadError: olderLoadError,
            nextHistoryCursor: nextHistoryCursor,
            restoredPosition: captureHistoryPosition()
        }
    }

    function restorePosition() {
        var position = restoredPosition
        if (!position) return
        var row = historyRows.itemAt(position.index)
        if (row) historyList.moveTo(row.y + Math.min(position.inset, row.height - 1))
    }

    function updateHistoryPageStops() {
        if (historyColumn) historyList.pageStops = historyList.rowPageStops(historyColumn.children)
    }

    function requestFiltered() {
        if (!gameHistoryScreen.backendSender || !gameHistoryScreen.nextRequestId) return
        gameHistoryScreen.loading = true
        gameHistoryScreen.errorMessage = ""
        gameHistoryScreen.loadError = ""
        gameHistoryScreen.olderLoadError = ""
        gameHistoryScreen.nextHistoryCursor = null
        gameHistoryScreen.restoredPosition = null
        gameHistoryScreen.games = []
        sendHistoryRequest(null)
    }

    function loadOlderGames() {
        if (!nextHistoryCursor || pendingHistoryRequest || openingReview) return
        olderLoadError = ""
        sendHistoryRequest(nextHistoryCursor)
    }

    function sendHistoryRequest(cursor) {
        gameHistoryScreen.pendingHistoryRequest = gameHistoryScreen.nextRequestId()
        var request = {
            type: "RequestGameHistory",
            request_id: gameHistoryScreen.pendingHistoryRequest,
            rated: gameHistoryScreen.filterRated === "all" ? null : gameHistoryScreen.filterRated === "rated",
            speed: gameHistoryScreen.filterSpeed === "all" ? null : gameHistoryScreen.filterSpeed,
            color: gameHistoryScreen.filterColor === "all" ? null : gameHistoryScreen.filterColor
        }
        if (cursor) request.cursor = cursor
        gameHistoryScreen.backendSender(request)
    }

    function appendHistory(newGames) {
        var seen = new Set(games.map(function(game) { return game.game_id }))
        var added = newGames.filter(function(game) {
            if (seen.has(game.game_id)) return false
            seen.add(game.game_id)
            return true
        })
        if (!added.length) return
        restoredPosition = captureHistoryPosition()
        games = games.concat(added)
    }

    function capitalized(value) {
        return value.charAt(0).toUpperCase() + value.slice(1)
    }

    function filterSummary() {
        var gameType = filterRated === "all" ? "All games" : capitalized(filterRated)
        var speed = filterSpeed === "all" ? "All speeds" : capitalized(filterSpeed)
        var side = filterColor === "all" ? "Both sides" : "Played " + capitalized(filterColor)
        return gameType + " · " + speed + " · " + side
    }

    function openFilters() {
        draftRated = filterRated
        draftSpeed = filterSpeed
        draftColor = filterColor
        showFilters = true
    }

    function applyFilters() {
        var changed = filterRated !== draftRated ||
            filterSpeed !== draftSpeed || filterColor !== draftColor
        filterRated = draftRated
        filterSpeed = draftSpeed
        filterColor = draftColor
        showFilters = false
        if (changed) requestFiltered()
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
            detail: gameHistoryScreen.openingReview ? "Opening game…"
                : (gameHistoryScreen.loading ? "Loading your games"
                   : gameHistoryScreen.games.length + " recent games")
        }

        // Drafting in a dialog avoids a network request on every tap; instant
        // filters chatter, while a separate filter screen loses archive context.
        MenuRow {
            width: parent.width
            darkMode: gameHistoryScreen.darkMode
            title: "Filters"
            subtitle: gameHistoryScreen.filterSummary()
            marker: "Change"
            onClicked: gameHistoryScreen.openFilters()
        }

        Text {
            visible: gameHistoryScreen.loading ||
                (gameHistoryScreen.games.length === 0 && gameHistoryScreen.loadError.length === 0)
            text: gameHistoryScreen.loading ? "Loading games..." : "No games match these filters."
            font.pixelSize: theme.fontBody
            color: theme.text
        }

        Text {
            visible: text.length > 0
            text: gameHistoryScreen.loadError || gameHistoryScreen.errorMessage
            font.pixelSize: theme.fontBody
            color: theme.errorText
            wrapMode: Text.WordWrap
            width: parent.width
        }
        AppButton {
            width: parent.width
            compact: true
            visible: gameHistoryScreen.loadError.length > 0
            text: "Retry"
            onClicked: gameHistoryScreen.requestFiltered()
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
        objectName: "historyList"
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
        onPageHeightChanged: gameHistoryScreen.updateHistoryPageStops()
        onMaximumContentYChanged: gameHistoryScreen.restorePosition()
        onPageNavigationRequested: gameHistoryScreen.restoredPosition = null

        Column {
            id: historyColumn
            width: parent.width
            spacing: theme.spacingSmall
            // Nested rows can reflow after their first layout at the Loader's width.
            onPositioningComplete: {
                gameHistoryScreen.updateHistoryPageStops()
                gameHistoryScreen.restorePosition()
            }

            Repeater {
                id: historyRows
                model: gameHistoryScreen.games

                Rectangle {
                id: gameCard
                objectName: "historyGameRow"
                required property var modelData
                readonly property var analysis: modelData.your_analysis || null
                readonly property bool canReview: modelData.review_supported !== false
                readonly property string variantLabel: chessDisplay.variantLabel(modelData.variant)
                width: parent.width
                // Never thinner than the shared list-row touch floor, however
                // little text a row happens to have.
                height: Math.max(rowContent.height + theme.spacingMedium, theme.listRowHeight)
                color: theme.cardBackground
                border.width: 1
                border.color: theme.cardBorder
                radius: theme.cardRadius
                clip: true

                Rectangle {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: theme.sectionRailWidth
                    color: gameHistoryScreen.resultColor(modelData.result)
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: gameCard.canReview
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

                    Flow {
                        id: gameHeading
                        width: parent.width
                        spacing: theme.spacingXs
                        Row {
                            id: resultRow
                            spacing: theme.spacingXs

                            Text {
                                objectName: "historyResult"
                                width: Math.min(Math.ceil(implicitWidth), Math.max(0, gameHeading.width -
                                    (ratingChange.visible ? ratingChange.width + resultRow.spacing : 0)))
                                text: chessDisplay.resultLabel(modelData.result)
                                font.pixelSize: theme.fontBody
                                font.bold: true
                                elide: Text.ElideRight
                                color: gameHistoryScreen.resultColor(modelData.result)
                            }

                            Text {
                                id: ratingChange
                                objectName: "historyRatingChange"
                                width: Math.ceil(implicitWidth)
                                visible: modelData.rating_diff !== null && modelData.rating_diff !== undefined
                                text: visible ? (modelData.rating_diff > 0 ? "+" : "") + modelData.rating_diff : ""
                                font.pixelSize: theme.fontBody
                                color: modelData.rating_diff > 0 ? theme.winText
                                    : (modelData.rating_diff < 0 ? theme.lossText : theme.textMuted)
                            }
                        }

                        Row {
                            id: opponentRow
                            spacing: theme.spacingXs
                            readonly property real inlineWidth: gameHeading.width - resultRow.width - gameHeading.spacing
                            readonly property real ratingSpace: opponentRating.visible ? opponentRating.width + spacing : 0
                            // Let the identity wrap as a unit on narrow rows. Smaller text
                            // hurts legibility and a permanent second line wastes space.
                            readonly property real availableWidth: inlineWidth >= ratingSpace + theme.fontBody * 3
                                ? inlineWidth : gameHeading.width

                            Text {
                                objectName: "historyOpponentName"
                                // Cap only the name after rounding up. A shared label can
                                // hide the rating, and rounding down clips fitting names.
                                width: Math.min(Math.ceil(implicitWidth), Math.max(0, opponentRow.availableWidth -
                                    opponentRow.ratingSpace))
                                text: "vs " + (modelData.opponent_name || "Opponent")
                                font.pixelSize: theme.fontBody
                                elide: Text.ElideRight
                                color: theme.text
                            }

                            Text {
                                id: opponentRating
                                objectName: "historyOpponentRating"
                                width: Math.ceil(implicitWidth)
                                text: modelData.opponent_rating ? "(" + modelData.opponent_rating + ")" : ""
                                visible: text.length > 0
                                font.pixelSize: theme.fontBody
                                color: theme.text
                            }
                        }
                    }

                    Text {
                        objectName: "historyGameDetails"
                        text: (modelData.rated ? "Rated" : "Casual") +
                              (modelData.speed ? " · " + chessDisplay.speedLabel(modelData.speed) : "") +
                              (gameCard.variantLabel ? " · " + gameCard.variantLabel : "") +
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
                        objectName: "historyAnalysis"
                        visible: text.length > 0
                        text: gameCard.analysis
                            ? "Accuracy " +
                              (gameCard.analysis.accuracy !== null && gameCard.analysis.accuracy !== undefined
                                  ? gameCard.analysis.accuracy + "%"
                                  : "n/a") +
                              " · " + gameCard.analysis.blunders + " blunders, " +
                              gameCard.analysis.mistakes + " mistakes"
                            : ""
                        font.pixelSize: theme.fontSmall
                        wrapMode: Text.WordWrap
                        width: rowContent.width
                        color: theme.textMuted
                    }

                    Text {
                        objectName: "historyReviewUnavailable"
                        visible: !gameCard.canReview
                        text: "Review unavailable"
                        font.pixelSize: theme.fontSmall
                        width: rowContent.width
                        wrapMode: Text.WordWrap
                        color: theme.textMuted
                    }
                }
                }
            }

            // Load on demand at the end of the list. Automatic loads fetch
            // unrequested games, and a pinned footer takes space on every page.
            MenuRow {
                objectName: "loadOlderGamesButton"
                width: historyColumn.width
                height: theme.buttonMinHeight + theme.spacingSmall
                visible: gameHistoryScreen.nextHistoryCursor !== null
                darkMode: gameHistoryScreen.darkMode
                enabled: !gameHistoryScreen.loadingOlder && !gameHistoryScreen.openingReview
                title: gameHistoryScreen.loadingOlder ? "Loading older games…"
                    : gameHistoryScreen.olderLoadError ? "Retry loading older games" : "Load older games"
                subtitle: gameHistoryScreen.olderLoadError
                onClicked: gameHistoryScreen.loadOlderGames()
            }
        }
    }

    AppDialog {
        anchors.fill: parent
        visible: gameHistoryScreen.showFilters
        darkMode: gameHistoryScreen.darkMode
        title: "Filter games"
        onDismissed: gameHistoryScreen.showFilters = false

        Text { text: "Game type"; font.pixelSize: theme.fontLabel; color: theme.textMuted }
        Flow {
            width: parent.width
            spacing: theme.spacingXs
            Repeater {
                model: ["all", "rated", "casual"]
                AppButton {
                    required property string modelData
                    text: gameHistoryScreen.capitalized(modelData)
                    highlighted: gameHistoryScreen.draftRated === modelData
                    onClicked: gameHistoryScreen.draftRated = modelData
                }
            }
        }

        Text { text: "Speed"; font.pixelSize: theme.fontLabel; color: theme.textMuted }
        Flow {
            width: parent.width
            spacing: theme.spacingXs
            Repeater {
                model: ["all", "bullet", "blitz", "rapid", "classical", "correspondence"]
                AppButton {
                    required property string modelData
                    text: gameHistoryScreen.capitalized(modelData)
                    highlighted: gameHistoryScreen.draftSpeed === modelData
                    onClicked: gameHistoryScreen.draftSpeed = modelData
                }
            }
        }

        Text { text: "Side"; font.pixelSize: theme.fontLabel; color: theme.textMuted }
        Flow {
            width: parent.width
            spacing: theme.spacingXs
            Repeater {
                model: ["all", "white", "black"]
                AppButton {
                    required property string modelData
                    text: gameHistoryScreen.capitalized(modelData)
                    highlighted: gameHistoryScreen.draftColor === modelData
                    onClicked: gameHistoryScreen.draftColor = modelData
                }
            }
        }

        AppButton {
            width: parent.width
            text: "Reset filters"
            onClicked: {
                gameHistoryScreen.draftRated = "all"
                gameHistoryScreen.draftSpeed = "all"
                gameHistoryScreen.draftColor = "all"
            }
        }

        AppButton {
            width: parent.width
            text: "Show games"
            highlighted: true
            onClicked: gameHistoryScreen.applyFilters()
        }
    }

    function handleMessage(msg) {
        if (msg.type === "GameHistory" || msg.type === "GameHistoryFailed") {
            if (msg.request_id !== gameHistoryScreen.pendingHistoryRequest) return
            var older = gameHistoryScreen.loadingOlder
            gameHistoryScreen.pendingHistoryRequest = 0
            gameHistoryScreen.loading = false
            if (msg.type === "GameHistory") {
                if (older) gameHistoryScreen.appendHistory(msg.games || [])
                else gameHistoryScreen.games = msg.games || []
                gameHistoryScreen.nextHistoryCursor = msg.next_cursor || null
            } else if (older) {
                gameHistoryScreen.olderLoadError = msg.message || "Lichess could not load older games."
            } else {
                gameHistoryScreen.loadError = msg.message
            }
        } else if (msg.type === "GameMovesFailed") {
            gameHistoryScreen.errorMessage = msg.message
        }
    }
}
