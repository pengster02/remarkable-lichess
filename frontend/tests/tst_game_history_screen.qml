import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    id: testCase
    name: "GameHistoryScreen"
    when: windowShown
    width: 960
    height: 1696

    property var sentMessages: []
    property int requestSequence: 0

    GameHistoryScreen {
        id: history
        width: 960
        height: 1696
        backendSender: function(message) { testCase.sentMessages.push(message) }
        nextRequestId: function() { return ++testCase.requestSequence }
        navigateTo: function() {}
        selectGameForReview: function() {}
    }

    function init() {
        sentMessages = []
        history.filterRated = "all"
        history.filterSpeed = "all"
        history.filterColor = "all"
        history.showFilters = false
        history.loading = false
        history.errorMessage = ""
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
}
