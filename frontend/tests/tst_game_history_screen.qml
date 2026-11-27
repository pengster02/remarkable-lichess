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
        height = 1696
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

    function loadGames(games) {
        history.requestFiltered()
        var request = sentMessages[sentMessages.length - 1].request_id
        history.handleMessage({type: "GameHistory", request_id: request,
                               games: games})
    }

    function showGame(fields) {
        var game = {game_id: "selected", opponent_name: "Opponent", rated: true,
                    speed: "rapid", result: "win", termination: "Resignation"}
        loadGames([Object.assign(game, fields)])
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
            {tag: "partial counter", fields: {your_analysis: {accuracy: 100, blunders: null, mistakes: 0}},
                text: "Accuracy 100% · 0 mistakes"},
            {tag: "percent only", fields: {your_analysis: {accuracy: 90}}, text: "Accuracy 90%"},
            {tag: "no displayable data", fields: {your_analysis: {accuracy: 101, acpl: 12}}, text: ""},
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

    function test_variantLabelAndReviewAvailability_data() {
        return [
            {tag: "standard", fields: {variant: "standard", review_supported: true},
                label: "", canReview: true},
            {tag: "custom starting position", fields: {variant: "fromPosition", review_supported: true},
                label: "Custom position", canReview: true},
            {tag: "no variant metadata", fields: {variant: null, review_supported: null},
                label: "", canReview: true},
            {tag: "older backend", fields: {}, label: "", canReview: true},
            {tag: "known unsupported variant", fields: {variant: "crazyhouse", review_supported: false},
                label: "Crazyhouse", canReview: false},
            {tag: "unknown variant", fields: {variant: "futureVariant", review_supported: false},
                label: "Future Variant", canReview: false}
        ]
    }

    function test_variantLabelAndReviewAvailability(data) {
        width = 620
        var row = showGame(data.fields)
        var details = findChild(row, "historyGameDetails")
        var unavailable = findChild(row, "historyReviewUnavailable")
        compare(details.text, "Rated · Rapid" + (data.label ? " · " + data.label : "") + " · Resignation")
        compare(unavailable.visible, !data.canReview)
        if (!data.canReview) compare(unavailable.text, "Review unavailable")

        mouseClick(row, row.width / 2, row.height / 2)
        if (data.canReview) compare(selectedGame.game_id, "selected")
        else compare(selectedGame, null)
    }

    function gamesForPaging(count, mixed, oversized) {
        var games = []
        for (var i = 0; i < count; i++) {
            var game = {game_id: "archive-" + i, opponent_name: "Opponent " + i,
                        opponent_rating: 1800, result: "win", termination: "Checkmate",
                        speed: "rapid", rated: true}
            if (mixed && i % 2 === 1) {
                game.opponent_name = "WWWWWWWWWWWWWWWWWWWW"
                game.result = "noStart"
                game.variant = "crazyhouse"
                game.review_supported = false
                game.your_analysis = {accuracy: 91, blunders: 0, mistakes: 3}
            }
            if (oversized && (i === 4 || i === count - 1))
                game.opening_name = "A long opening description with several words ".repeat(35)
            games.push(game)
        }
        return games
    }

    function test_cardsFitOnReachablePages_data() {
        return [
            {tag: "ordinary tablet and uniform rows", width: 954, height: 1696,
                mixed: false, oversized: false},
            {tag: "compact viewport and wrapped details", width: 620, height: 1380,
                mixed: true, oversized: false},
            {tag: "oversized cards between and after shorter cards", width: 620, height: 1380,
                mixed: true, oversized: true}
        ]
    }

    function test_cardsFitOnReachablePages(data) {
        width = data.width
        height = data.height
        loadGames(gamesForPaging(20, data.mixed, data.oversized))
        var first = findChild(history, "historyGameRow")
        verify(first && waitForRendering(first))
        var rows = Array.prototype.filter.call(first.parent.children, function(child) {
            return child.objectName === "historyGameRow"
        })
        compare(rows.length, 20)
        var pager = findChild(history, "historyList")
        var viewport = findChild(pager, "pagedViewport")
        var next = findChild(pager, "pageDownButton")
        var previous = findChild(pager, "pageUpButton")
        var number = findChild(pager, "pageNumber")
        pager.moveTo(0)
        verify(next.visible && next.enabled)
        if (data.mixed) verify(rows[1].height > rows[0].height)
        compare(rows.some(function(row) { return row.height > pager.pageHeight }), data.oversized)

        var stops = [0]
        var ends = [viewport.height]
        for (var page = 1; page < pager.pageCount; page++) {
            verify(next.enabled)
            next.clicked()
            verify(pager.contentY > stops[page - 1])
            stops.push(pager.contentY)
            ends.push(pager.contentY + viewport.height)
            compare(number.text, (page + 1) + " / " + pager.pageCount)
        }
        verify(!next.enabled)
        fuzzyCompare(pager.contentY, pager.maximumContentY, 0.01)
        for (var row of rows) {
            var visiblePages = []
            var bottom = row.y + row.height
            for (var index = 0; index < stops.length; ++index) {
                if (row.y < ends[index] - 0.01 && bottom > stops[index] + 0.01) visiblePages.push(index)
            }
            verify(visiblePages.length > 0)
            if (row.height <= pager.pageHeight) {
                compare(visiblePages.length, 1, row.modelData.game_id + " is split across pages")
                verify(row.y >= stops[visiblePages[0]] - 0.01 && bottom <= ends[visiblePages[0]] + 0.01)
            } else {
                verify(row.y >= stops[visiblePages[0]] - 0.01 && bottom <= ends[visiblePages[visiblePages.length - 1]] + 0.01)
                for (var fragment = 1; fragment < visiblePages.length; ++fragment) {
                    var before = visiblePages[fragment - 1]
                    fuzzyCompare(ends[before], stops[visiblePages[fragment]], 0.01)
                }
            }
        }
        for (var index = stops.length - 2; index >= 0; index--) {
            previous.clicked()
            fuzzyCompare(pager.contentY, stops[index], 0.01)
        }
        verify(!previous.enabled)
    }

    function test_oversizedCardOnlyOpensFromThePageWithItsHeading() {
        width = 620
        height = 1380
        loadGames(gamesForPaging(20, true, true))
        var pager = findChild(history, "historyList")
        var first = findChild(history, "historyGameRow")
        verify(first && waitForRendering(pager))
        var rows = Array.prototype.filter.call(first.parent.children, function(child) {
            return child.objectName === "historyGameRow"
        })
        var oversized = rows[4]
        var heading = findChild(oversized, "historyOpponentName")
        pager.showPageContaining(oversized.y, oversized.height)
        mouseClick(heading, heading.width / 2, heading.height / 2)
        compare(selectedGame.game_id, "archive-4")
        selectedGame = null

        pager.pageDown()
        var top = pager.contentY - oversized.y
        verify(top > heading.mapToItem(oversized, 0, heading.height).y)
        verify(top + 50 < oversized.height)
        mouseClick(oversized, oversized.width / 2, top + 50)
        compare(selectedGame, null)
    }

    function test_shorterResultsRemoveOldPageStops() {
        var pager = findChild(history, "historyList")
        var next = findChild(pager, "pageDownButton")
        loadGames(gamesForPaging(20, false, false))
        tryVerify(function() { return next.enabled && pager.pageStops.length > 0 })
        next.clicked()
        verify(pager.contentY > 0)

        loadGames(gamesForPaging(2, false, false))
        tryCompare(pager, "pageCount", 1)
        tryCompare(pager, "pageStops", [])
        verify(!next.visible)
        compare(pager.contentY, 0)
    }
}
