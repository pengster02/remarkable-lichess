import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    id: testCase
    name: "GameHistoryScreen"
    when: windowShown
    visible: true
    width: 954
    height: 1696

    property var sentMessages: []
    property int requestSequence: 0
    property var selectedGame: null

    GameHistoryScreen {
        id: history
        backendSender: function(message) { testCase.sentMessages.push(message) }
        nextRequestId: function() { return ++testCase.requestSequence }
        navigateTo: function() {}
        selectGameForReview: function(game) { testCase.selectedGame = game }
    }

    function init() {
        sentMessages = []
        selectedGame = null
        width = 954
        history.filterRated = "all"
        history.filterSpeed = "all"
        history.filterColor = "all"
        history.showFilters = false
        history.loading = false
        history.errorMessage = ""
        history.loadError = ""
        history.games = []
    }

    function test_draftFiltersDoNotRequestUntilApplied() {
        history.openFilters()
        history.draftRated = "rated"
        history.draftSpeed = "rapid"
        history.draftColor = "white"
        compare(sentMessages.length, 0)

        history.applyFilters()
        compare(sentMessages.length, 1)
        compare(sentMessages[0].type, "RequestGameHistory")
        compare(sentMessages[0].rated, true)
        compare(sentMessages[0].speed, "rapid")
        compare(sentMessages[0].color, "white")
        compare(history.showFilters, false)
        compare(history.loading, true)
    }

    function test_unchangedFiltersCloseWithoutNetworkChatter() {
        history.openFilters()
        history.applyFilters()
        compare(sentMessages.length, 0)
        compare(history.showFilters, false)
    }

    function test_filterSummaryUsesReadableLabels() {
        history.filterRated = "casual"
        history.filterSpeed = "blitz"
        history.filterColor = "black"
        compare(history.filterSummary(), "Casual · Blitz · Played Black")
    }

    function test_loadErrorStopsProgressAndRemainsVisible() {
        history.requestFiltered()
        history.handleMessage({type: "GameHistoryFailed", request_id: sentMessages[0].request_id,
                               message: "History unavailable"})
        compare(history.loading, false)
        compare(history.loadError, "History unavailable")
    }

    function test_filterChangeClearsOldRowsAndRejectsOlderReplies() {
        history.requestFiltered()
        var first = sentMessages[0].request_id
        verify(first > 0)
        history.handleMessage({type: "GameHistory", request_id: first,
                               games: [{game_id: "old"}]})
        compare(history.games[0].game_id, "old")

        history.filterRated = "rated"
        history.requestFiltered()
        var second = sentMessages[1].request_id
        verify(second > first)
        compare(history.games.length, 0)
        history.handleMessage({type: "GameHistory", request_id: first,
                               games: [{game_id: "old"}]})
        history.handleMessage({type: "GameHistoryFailed", request_id: first, message: "old failure"})
        verify(history.loading)
        compare(history.games.length, 0)
        compare(history.loadError, "")
        history.handleMessage({type: "GameHistory", request_id: second,
                               games: [{game_id: "selected", rated: true}]})
        verify(!history.loading)
        compare(history.games[0].game_id, "selected")
    }

    function showGame(fields) {
        history.requestFiltered()
        var request = sentMessages[sentMessages.length - 1].request_id
        var game = {game_id: "selected", opponent_name: "Opponent", rated: true,
                    speed: "rapid", result: "win", termination: "Resignation"}
        history.handleMessage({type: "GameHistory", request_id: request,
                               games: [Object.assign(game, fields)]})
        var row = findChild(history, "historyGameRow")
        verify(row && waitForRendering(row))
        return row
    }

    function test_historyHeadingFitsItsCard_data() {
        return [
            {tag: "natural name", viewport: 954, name: "Opponent", result: "win",
                truncated: false, wrapped: false},
            {tag: "long name", viewport: 954, name: "WWWWWWWWWWWWWWWWWWWW", result: "win",
                truncated: true, wrapped: false},
            {tag: "narrow card with long result and name", viewport: 620,
                name: "WWWWWWWWWWWWWWWWWWWW", result: "noStart", truncated: true, wrapped: true}
        ]
    }

    function test_historyHeadingFitsItsCard(data) {
        width = data.viewport
        tryCompare(history, "width", data.viewport)
        var row = showGame({opponent_name: data.name, opponent_rating: 2345, result: data.result,
                            rating_diff: 0, your_analysis: null})
        var name = findChild(row, "historyOpponentName")
        var rating = findChild(row, "historyOpponentRating")
        var delta = findChild(row, "historyRatingChange")
        var result = findChild(row, "historyResult")
        var heading = name.parent.parent
        compare(name.text, "vs " + data.name)
        compare(name.truncated, data.truncated)
        compare(name.parent.y > 0, data.wrapped)
        verify(rating.visible && !rating.truncated)
        compare(rating.text, "(2345)")
        verify(delta.visible && !delta.truncated)
        compare(delta.text, "0")
        for (var label of [name, rating, delta, result]) {
            verify(label.mapToItem(heading, label.width, 0).x <= heading.width)
        }

        mouseClick(row, row.width / 2, row.height / 2)
        verify(selectedGame)
        compare(selectedGame.game_id, "selected")
        compare(selectedGame.opponent_name, data.name)
        compare(selectedGame.opponent_rating, 2345)
    }

    function test_analysisUsesOptionalData_data() {
        return [
            {tag: "omitted", fields: {}, text: ""},
            {tag: "explicit null", fields: {your_analysis: null}, text: ""},
            {tag: "accuracy zero", fields: {your_analysis: {accuracy: 0, blunders: 0, mistakes: 2}},
                text: "Accuracy 0% · 0 blunders, 2 mistakes"},
            {tag: "accuracy unknown", fields: {your_analysis: {accuracy: null, blunders: 1, mistakes: 0}},
                text: "Accuracy n/a · 1 blunders, 0 mistakes"}
        ]
    }

    function test_analysisUsesOptionalData(data) {
        var row = showGame(data.fields)
        var analysis = findChild(row, "historyAnalysis")
        compare(analysis.visible, data.text.length > 0)
        compare(analysis.text, data.text)
        verify(!findChild(row, "historyRatingChange").visible)
        verify(!findChild(row, "historyOpponentRating").visible)
    }
}
