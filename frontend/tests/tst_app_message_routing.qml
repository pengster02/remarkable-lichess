import QtQuick 2.5
import QtTest 1.2

TestCase {
    name: "AppMessageRouting"
    when: windowShown
    visible: true
    width: 954
    height: 1696

    property var app
    property var endpoint
    property var screen
    property string startFen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    function init() {
        width = 954
        var component = Qt.createComponent("../ui/main.qml")
        compare(component.status, Component.Ready, component.errorString())
        app = createTemporaryObject(component, this)
        verify(app)
        endpoint = findChild(app, "testAppLoadEndpoint")
        screen = findChild(app, "screenLoader")
        endpoint.reply({type: "TokenVerified", username: "player"})
        app.navigateTo("GameHistoryScreen.qml")
    }

    function choose(gameId) {
        screen.item.selectGameForReview({game_id: gameId, opponent_name: gameId})
        return endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
    }

    function replyWithMoves(requestId, move) {
        endpoint.reply({type: "GameMoves", request_id: requestId,
                        moves: [move], fens: [startFen, startFen]})
    }

    function boardState(gameId) {
        return {
            type: "BoardState", game_id: gameId, fen: startFen,
            turn: "white", your_color: "white",
            white_time_ms: 600000, black_time_ms: 600000,
            legal_moves: [], position_history: [startFen], move_history: []
        }
    }

    function latestHomeRequest() {
        var messages = endpoint.sentMessages.filter(function(message) {
            return message.type === "RequestHome"
        })
        return messages[messages.length - 1].request_id
    }

    function test_homeGamesAndRatingsAreScopedToTheCurrentVisit() {
        app.navigateTo("HomeScreen.qml")
        var home = screen.item
        var previous = latestHomeRequest()
        verify(previous > 0)
        home.refresh()
        var current = latestHomeRequest()
        verify(current > previous)

        endpoint.reply({type: "HomeLoadFailed", request_id: previous,
                        wifi_connected: false, message: "Old failure"})
        endpoint.reply({type: "HomeRatings", request_id: previous,
                        ratings: [{speed: "rapid", rating: 900}]})
        compare(home.loadedOnce, false)
        compare(home.loadError, "")
        compare(home.ratings.length, 0)

        endpoint.reply({type: "HomeState", request_id: current, wifi_connected: true,
                        ongoing_games: [{game_id: "ongoing", is_my_turn: true}]})
        verify(home.loadedOnce)
        verify(app.online)
        compare(home.ratings.length, 0)
        var resume = findChild(home, "homeResumeButton")
        verify(resume && resume.enabled)
        resume.clicked()
        verify(String(screen.source).endsWith("BoardScreen.qml"))
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "ResumeGame", game_id: "ongoing"})

        endpoint.reply({type: "HomeLoadFailed", request_id: current,
                        wifi_connected: false, message: "Departed screen"})
        verify(app.online)
        endpoint.reply({type: "AuthenticationRequired"})
        endpoint.reply({type: "HomeRatings", request_id: current,
                        ratings: [{speed: "rapid", rating: 900}]})
        verify(String(screen.source).endsWith("LoginScreen.qml"))
        endpoint.reply({type: "TokenVerified", username: "new player"})
        home = screen.item
        compare(home.ratings.length, 0)
        var reopened = latestHomeRequest()
        verify(reopened > current)
        endpoint.reply({type: "HomeRatings", request_id: reopened,
                        ratings: [{speed: "rapid", rating: 1500}]})
        compare(home.ratings[0].rating, 1500)
        verify(!home.loadedOnce)
    }

    function test_homeRatingsDoNotMoveTheResumeButton() {
        app.navigateTo("HomeScreen.qml")
        var home = screen.item
        var request = latestHomeRequest()
        endpoint.reply({type: "HomeState", request_id: request, wifi_connected: true,
                        ongoing_games: [{game_id: "ongoing", is_my_turn: true}]})
        var resume = findChild(home, "homeResumeButton")
        verify(resume && resume.enabled)
        waitForRendering(resume)
        var before = resume.mapToItem(home, 0, 0).y
        endpoint.reply({type: "HomeRatings", request_id: request,
                        ratings: [{speed: "rapid", rating: 1500}]})
        verify(waitForRendering(resume))
        compare(resume.mapToItem(home, 0, 0).y, before)
        compare(home.ratings[0].rating, 1500)
    }

    function test_accountStartsRefreshOnlyTheVisibleGamesList() {
        app.navigateTo("HomeScreen.qml")
        var home = screen.item
        var first = latestHomeRequest()
        endpoint.reply({type: "HomeState", request_id: first, ongoing_games: [], wifi_connected: true})
        var before = endpoint.sentMessages.length
        endpoint.reply({type: "GameStarted", game_id: "other-client", from_realtime_lobby: false})
        endpoint.reply({type: "GameStarted", game_id: "also-elsewhere", from_realtime_lobby: true})
        tryVerify(function() { return latestHomeRequest() > first })
        var current = latestHomeRequest()
        compare(endpoint.sentMessages.length, before + 1)
        compare(endpoint.sentMessages[before], {type: "RequestHome", request_id: current, games_only: true})
        verify(String(screen.source).endsWith("HomeScreen.qml"))
        verify(home.loadedOnce)
        verify(app.online)
        endpoint.reply({type: "HomeRatings", request_id: first,
                        ratings: [{speed: "rapid", rating: 1600}]})
        compare(home.ratings[0].rating, 1600)
        endpoint.reply({type: "HomeRatings", request_id: current,
                        ratings: [{speed: "rapid", rating: 900}]})
        compare(home.ratings[0].rating, 1600)
        endpoint.reply({type: "HomeState", request_id: current,
                        ongoing_games: [{game_id: "other-client", is_my_turn: true}]})
        compare(home.ongoingGames[0].game_id, "other-client")

        endpoint.reply({type: "GameStarted", game_id: "other-client", from_realtime_lobby: false})
        verify(!home.gamesRefreshQueued)
        var resume = findChild(home, "homeResumeButton")
        verify(resume !== null)
        endpoint.reply({type: "AccountEventsResumed"})
        tryVerify(function() { return latestHomeRequest() > current })
        endpoint.reply({type: "HomeState", request_id: latestHomeRequest(),
                        ongoing_games: [{game_id: "other-client", is_my_turn: true}]})
        compare(findChild(home, "homeResumeButton"), resume)
        app.navigateTo("SettingsScreen.qml")
        var away = latestHomeRequest()
        endpoint.reply({type: "GameStarted", game_id: "away", from_realtime_lobby: false})
        endpoint.reply({type: "GameFinished", game_id: "other-client"})
        endpoint.reply({type: "AccountEventsResumed"})
        compare(latestHomeRequest(), away)
        verify(String(screen.source).endsWith("SettingsScreen.qml"))
    }

    function test_gameFinishesCannotBeRestoredByAnOlderGamesSnapshot() {
        app.navigateTo("HomeScreen.qml")
        var home = screen.item
        var first = latestHomeRequest()
        var finished = {game_id: "completed", is_my_turn: true}
        var active = {game_id: "continues", is_my_turn: false}
        endpoint.reply({type: "HomeState", request_id: first, ongoing_games: [finished, active], wifi_connected: true})
        endpoint.reply({type: "AccountEventsResumed"})
        tryVerify(function() { return latestHomeRequest() > first })
        var inFlight = latestHomeRequest()
        endpoint.reply({type: "GameFinished", game_id: "completed"})
        endpoint.reply({type: "GameFinished", game_id: "completed"})
        endpoint.reply({type: "GameStarted", game_id: "arriving", from_realtime_lobby: false})
        verify(home.gamesRefreshQueued)
        compare(home.ongoingGames, [active])
        compare(latestHomeRequest(), inFlight)

        endpoint.reply({type: "HomeState", request_id: inFlight, ongoing_games: [finished, active]})
        compare(home.ongoingGames, [active])
        tryVerify(function() { return latestHomeRequest() > inFlight })
        var latest = latestHomeRequest()
        endpoint.reply({type: "HomeState", request_id: inFlight, ongoing_games: [finished]})
        compare(home.ongoingGames, [active])
        var arriving = {game_id: "arriving", is_my_turn: true}
        endpoint.reply({type: "HomeState", request_id: latest, ongoing_games: [active, arriving]})
        compare(home.ongoingGames, [active, arriving])
        compare(home.finishedGameIds.length, 0)
        verify(!home.gamesRefreshQueued)
    }

    function test_eventRefreshWaitsForTheGamesRateLimit() {
        app.navigateTo("HomeScreen.qml")
        var home = screen.item
        var first = latestHomeRequest()
        var active = {game_id: "existing", is_my_turn: true}
        endpoint.reply({type: "HomeState", request_id: first, ongoing_games: [active], wifi_connected: true})
        endpoint.reply({type: "AccountEventsResumed"})
        tryVerify(function() { return latestHomeRequest() > first })
        var limited = latestHomeRequest()
        endpoint.reply({type: "HomeLoadFailed", request_id: limited,
                        message: "Lichess is limiting game-list requests.", retry_after_ms: 600})
        endpoint.reply({type: "GameStarted", game_id: "arriving", from_realtime_lobby: false})
        compare(home.ongoingGames, [active])
        verify(app.online)
        wait(350)
        compare(latestHomeRequest(), limited)
        tryVerify(function() { return latestHomeRequest() > limited })
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1].games_only, true)
    }

    function test_latestSelectionGetsItsOwnReplayAndHeader() {
        var first = choose("first")
        var messageCount = endpoint.sentMessages.length
        screen.item.selectGameForReview({game_id: "unavailable", review_supported: false})
        compare(endpoint.sentMessages.length, messageCount)
        verify(screen.item.openingReview)
        compare(choose("first"), first)
        compare(endpoint.sentMessages.length, messageCount)
        var second = choose("second")
        verify(first !== second)
        verify(screen.item.openingReview)

        replyWithMoves(first, "d4")
        verify(String(screen.source).endsWith("GameHistoryScreen.qml"))
        verify(screen.item.openingReview)
        replyWithMoves(second, "e4")
        verify(String(screen.source).endsWith("GameReviewScreen.qml"))
        compare(screen.item.game.game_id, "second")
        compare(screen.item.moves, ["e4"])
    }

    function applyHistoryFilters(speed) {
        screen.item.openFilters()
        screen.item.draftRated = "rated"
        screen.item.draftSpeed = speed
        screen.item.draftColor = "black"
        screen.item.applyFilters()
        return screen.item.pendingHistoryRequest
    }

    function historyRequests() {
        return endpoint.sentMessages.filter(function(message) {
            return message.type === "RequestGameHistory"
        })
    }

    function archiveRows(history) {
        var firstRow = findChild(history, "historyGameRow")
        return Array.prototype.filter.call(firstRow.parent.children, function(child) {
            return child.objectName === "historyGameRow"
        })
    }

    function openReviewFromPagedArchive(lastPage) {
        var requestId = applyHistoryFilters("rapid")
        var games = []
        for (var i = 0; i < 30; i++) {
            games.push({game_id: "archive-" + i, opponent_name: "WWWWWWWWWWWWWWWWWWWW",
                        opponent_rating: 1800, rating_diff: 0, result: "win", speed: "rapid",
                        termination: "Checkmate", rated: true,
                        opening_name: "Queen's Gambit Declined: Orthodox Defense, Rubinstein Variation"})
        }
        endpoint.reply({type: "GameHistory", request_id: requestId, games: games})
        var history = screen.item
        var pager = findChild(history, "historyList")
        var next = findChild(pager, "pageDownButton")
        tryVerify(function() { return next.visible && next.enabled })
        next.clicked()
        if (lastPage) {
            for (var page = 1; page < pager.pageCount && next.enabled; page++) next.clicked()
            verify(!next.enabled)
        }
        var row = archiveRows(history).find(function(card) {
            return card.y >= pager.contentY
        })
        verify(row && waitForRendering(row))
        mouseClick(row, row.width / 2, row.height / 2)
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "RequestGameMoves")
        compare(request.game_id, row.modelData.game_id)
        return request.request_id
    }

    function test_backFromArchiveReviewRestoresTheLoadedPage_data() {
        return [{tag: "same tablet size", width: 954, lastPage: false},
                {tag: "narrower on return", width: 620, lastPage: false},
                {tag: "same tablet size on the last page", width: 954, lastPage: true}]
    }

    function test_backFromArchiveReviewRestoresTheLoadedPage(data) {
        var request = openReviewFromPagedArchive(data.lastPage)
        var archive = screen.item
        var pager = findChild(archive, "historyList")
        var before = pager.contentY
        var anchorIndex = archiveRows(archive).findIndex(function(row) {
            return row.y + row.height > before
        })
        verify(anchorIndex > 0)
        var inset = before - archiveRows(archive)[anchorIndex].y
        var requestsBefore = historyRequests().length
        replyWithMoves(request, "e4")
        width = data.width
        findChild(screen.item, "reviewBackButton").clicked()

        var returned = screen.item
        compare(returned.filterSummary(), "Rated · Rapid · Played Black")
        compare(returned.games.length, 30)
        compare(returned.games[anchorIndex].game_id, "archive-" + anchorIndex)
        verify(!returned.loading)
        compare(historyRequests().length, requestsBefore)
        var restoredPager = findChild(returned, "historyList")
        tryVerify(function() { return restoredPager.contentY > 0 })
        var expected = archiveRows(returned)[anchorIndex].y + inset
        fuzzyCompare(restoredPager.contentY, expected, 0.01)
        if (data.width === 954) fuzzyCompare(restoredPager.contentY, before, 0.01)
        else verify(Math.abs(restoredPager.contentY - before) > 0.01)

        var previous = findChild(restoredPager, "pageUpButton")
        verify(previous.enabled)
        previous.clicked()
        verify(restoredPager.contentY < expected)
    }

    function test_backFromReviewRestartsOnlyAnUnfinishedHistoryRead() {
        var review = openReviewFromPagedArchive()
        var interrupted = applyHistoryFilters("blitz")
        var count = historyRequests().length
        replyWithMoves(review, "e4")
        tryVerify(function() {
            return endpoint.sentMessages.some(function(message) {
                return message.type === "CancelGameHistory" && message.request_id === interrupted
            })
        })
        findChild(screen.item, "reviewBackButton").clicked()

        var returned = screen.item
        var requests = historyRequests()
        compare(requests.length, count + 1)
        var resumed = requests[count]
        verify(resumed.request_id > interrupted)
        compare(resumed, {type: "RequestGameHistory", request_id: resumed.request_id,
                          rated: true, speed: "blitz", color: "black"})
        endpoint.reply({type: "GameHistory", request_id: interrupted, games: [{game_id: "stale"}]})
        verify(returned.loading)
        compare(returned.games.length, 0)
        endpoint.reply({type: "GameHistory", request_id: resumed.request_id, games: [{game_id: "current"}]})
        compare(returned.games[0].game_id, "current")
    }

    function test_backFromFinishedBoardReviewStartsAFreshArchive_data() {
        return [{tag: "same account", signOut: false}, {tag: "new account", signOut: true}]
    }

    function test_backFromFinishedBoardReviewStartsAFreshArchive(data) {
        replyWithMoves(openReviewFromPagedArchive(), "e4")
        if (data.signOut) {
            endpoint.reply({type: "AuthenticationRequired"})
            verify(String(screen.source).endsWith("LoginScreen.qml"))
            endpoint.reply({type: "TokenVerified", username: "other-account"})
        } else {
            app.navigateTo("HomeScreen.qml")
        }
        app.openGame("finished")
        var snapshot = boardState("finished")
        snapshot.outcome = {result: "draw", reason: "Draw"}
        endpoint.reply(snapshot)
        findChild(screen.item, "reviewFinishedGameButton").clicked()
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "RequestGameMoves")
        replyWithMoves(request.request_id, "e4")

        var count = historyRequests().length
        findChild(screen.item, "reviewBackButton").clicked()
        compare(historyRequests().length, count + 1)
        compare(screen.item.filterSummary(), "All games · All speeds · Both sides")
        compare(screen.item.games.length, 0)
        verify(screen.item.loading)
        compare(findChild(screen.item, "historyList").contentY, 0)
    }

    function test_leavingHistoryCancelsThePendingFilter() {
        var request = screen.item.pendingHistoryRequest
        verify(request > 0)
        app.navigateTo("HomeScreen.qml")
        tryVerify(function() {
            return endpoint.sentMessages.some(function(message) {
                return message.type === "CancelGameHistory" && message.request_id === request
            })
        })
        app.navigateTo("GameHistoryScreen.qml")
        var current = screen.item.pendingHistoryRequest
        verify(current > request)
        endpoint.reply({type: "GameHistory", request_id: request, games: [{game_id: "old"}]})
        verify(screen.item.loading)
        endpoint.reply({type: "GameHistory", request_id: current, games: []})
        verify(!screen.item.loading)
    }

    function test_backCancelsAndReopeningSameGameUsesADifferentRequest() {
        var abandoned = choose("same")
        app.navigateTo("HomeScreen.qml")
        var cancellations = endpoint.sentMessages.filter(function(message) {
            return message.type === "CancelGameReview"
        })
        compare(cancellations, [{type: "CancelGameReview", request_id: abandoned}])
        replyWithMoves(abandoned, "d4")
        verify(String(screen.source).endsWith("HomeScreen.qml"))
        app.navigateTo("GameHistoryScreen.qml")
        var current = choose("same")
        verify(abandoned !== current)
        endpoint.reply({type: "GameMovesFailed", request_id: abandoned, message: "old error"})
        compare(screen.item.errorMessage, "")

        endpoint.reply({type: "GameMovesFailed", request_id: current, message: "Game unavailable"})
        verify(String(screen.source).endsWith("GameHistoryScreen.qml"))
        compare(screen.item.errorMessage, "Game unavailable")
        verify(!screen.item.openingReview)
    }

    function test_terminalNoticeCannotNavAwayFromHistory() {
        endpoint.reply({type: "GameOver", game_id: "other", result: "draw", reason: "Draw"})
        verify(String(screen.source).endsWith("GameHistoryScreen.qml"))
    }

    function test_customReviewStartsFromTheExportedPosition() {
        endpoint.reply({type: "GameHistory", request_id: screen.item.pendingHistoryRequest,
                        games: [{game_id: "custom-start", variant: "fromPosition",
                                 review_supported: true, rated: false, speed: "rapid"}]})
        var card = findChild(screen.item, "historyGameRow")
        verify(card && waitForRendering(card))
        mouseClick(card, card.width / 2, card.height / 2)
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "RequestGameMoves")
        compare(request.game_id, "custom-start")
        var base = "4k3/4p3/8/8/8/8/P7/4K3 b - - 0 17"
        var afterBlack = "4k3/8/8/4p3/8/8/P7/4K3 w - - 0 18"
        var afterWhite = "4k3/8/8/4p3/P7/8/8/4K3 b - - 0 18"
        endpoint.reply({type: "GameMoves", request_id: request.request_id,
                        moves: ["e5", "a4"], fens: [base, afterBlack, afterWhite]})
        verify(String(screen.source).endsWith("GameReviewScreen.qml"))
        compare(screen.item.gameDetailsLabel(), "Casual · Rapid · Custom position")
        compare(screen.item.fens[0], base)
        var rows = screen.item.moveRows()
        compare(rows[0].number, 17)
        compare(rows[0].black.san, "e5")
        compare(rows[1].number, 18)
        compare(rows[1].white.san, "a4")
        screen.item.goNext()
        compare(screen.item.fens[screen.item.currentIndex], afterBlack)
    }

    function test_exploreResetRejectsALateMoveFromTheSamePosition() {
        var reviewId = choose("explore-game")
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: [], fens: [startFen]})
        var review = screen.item
        var legal = [{from: "e2", to: "e4"}, {from: "d2", to: "d4"}]
        review.beginExploration()
        var initial = review.pendingAnalysisRequestId
        endpoint.reply({type: "AnalysisPosition", request_id: initial, requested_fen: startFen,
                        fen: startFen, legal_moves: legal})
        verify(review.requestExplorationMove("e2", "e4"))
        var delayedMove = review.pendingAnalysisRequestId
        verify(!review.requestExplorationMove("d2", "d4"))

        review.rebaseExploration()
        var reset = review.pendingAnalysisRequestId
        verify(reset !== delayedMove)
        endpoint.reply({type: "AnalysisMove", request_id: delayedMove, from_fen: startFen,
                        fen: "stale position", san: "e4"})
        compare(review.exploreFen, startFen)
        compare(review.variationMoves.length, 0)
        compare(review.pendingAnalysisRequestId, reset)

        endpoint.reply({type: "AnalysisPosition", request_id: reset, requested_fen: startFen,
                        fen: startFen, legal_moves: legal})
        verify(review.requestExplorationMove("d2", "d4"))
        var currentMove = review.pendingAnalysisRequestId
        endpoint.reply({type: "AnalysisFailed", request_id: delayedMove, message: "old failure"})
        compare(review.pendingAnalysisRequestId, currentMove)
        endpoint.reply({type: "AnalysisFailed", request_id: currentMove, message: "Retry this move"})
        compare(review.pendingAnalysisRequestId, 0)
        compare(review.exploreStatus, "Retry this move")
        verify(review.requestExplorationMove("d2", "d4"))
    }

    function test_cancelExplorePromotionKeepsTheVariation() {
        var reviewId = choose("promotion-game")
        var fen = "7k/P7/8/8/8/8/8/4K3 w - - 0 1"
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: [], fens: [fen]})
        var review = screen.item
        review.beginExploration()
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: fen, fen: fen, legal_moves: [
                            {from: "a7", to: "a8", promotion: "n"},
                            {from: "a7", to: "a8", promotion: "q"}
                        ]})
        review.onExplorationGesture("a7", "a8")
        var cancel = findChild(review, "promotionCancelButton")
        verify(cancel && waitForRendering(cancel))
        var before = endpoint.sentMessages.length
        mouseClick(cancel, cancel.width / 2, cancel.height / 2)
        verify(!cancel.visible)
        compare(review.pendingPromotion, null)
        compare(review.pendingAnalysisRequestId, 0)
        compare(review.exploreFen, fen)
        compare(review.variationFens, [fen])
        compare(review.variationMoves, [])
        compare(endpoint.sentMessages.length, before)

        review.onExplorationGesture("a7", "a8")
        verify(cancel.visible)
        findChild(review, "promotionDialog").chosen("n")
        var move = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(move.type, "MakeAnalysisMove")
        compare(move.fen, fen)
        compare(move.promotion, "n")
        endpoint.reply({type: "AnalysisMove", request_id: move.request_id, from_fen: fen,
                        fen: "N6k/8/8/8/8/8/8/4K3 b - - 0 1", san: "a8=N"})
        compare(review.variationMoves, ["a8=N"])
    }

    function test_leavingReviewCancelsCloudEvaluationForThatReview() {
        var reviewId = choose("cloud-game")
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: [], fens: [startFen]})
        screen.item.requestCloudEvaluation()
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.review_id, reviewId)
        app.navigateTo("HomeScreen.qml")
        tryVerify(function() {
            return endpoint.sentMessages.some(function(message) {
                return message.type === "CancelCloudEvaluations" && message.review_id === reviewId
            })
        })
    }

    function test_cloudEvaluationKeepsEachPositionsRequestAndError() {
        var reviewId = choose("cloud-game")
        var afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: ["e4"], fens: [startFen, afterE4]})
        var review = screen.item
        review.requestCloudEvaluation()
        var first = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        review.goNext()
        review.requestCloudEvaluation()
        var second = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        verify(first.request_id !== second.request_id)
        var count = endpoint.sentMessages.length
        review.goPrev()
        compare(review.cloudEvaluationPhase, "pending")
        review.requestCloudEvaluation()
        compare(endpoint.sentMessages.length, count)

        endpoint.reply({type: "CloudEvaluationFailed", requested_fen: afterE4,
                        request_id: second.request_id, message: "Try this position again"})
        endpoint.reply({type: "CloudEvaluation", requested_fen: startFen,
                        request_id: first.request_id, evaluation: {depth: 24, knodes: 50, eval_cp: 10}})
        compare(review.currentCloudEvaluation().depth, 24)
        review.goNext()
        compare(review.cloudEvaluationLabel(), "Cloud evaluation failed: Try this position again")

        review.requestCloudEvaluation()
        var retry = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        endpoint.reply({type: "CloudEvaluationUnavailable", requested_fen: afterE4, request_id: second.request_id})
        compare(review.cloudEvaluationPhase, "pending")
        endpoint.reply({type: "CloudEvaluationUnavailable", requested_fen: afterE4, request_id: retry.request_id})
        compare(review.cloudEvaluationPhase, "unavailable")
    }

    function test_boardOnlyOpensFromAScreenThatExpectsPlay() {
        choose("selected-review")
        endpoint.reply({type: "GameStarted", game_id: "background", from_realtime_lobby: true})
        endpoint.reply(boardState("background"))
        verify(String(screen.source).endsWith("GameHistoryScreen.qml"))
        verify(screen.item.openingReview)

        app.navigateTo("SeekScreen.qml")
        endpoint.reply({type: "GameStarted", game_id: "background", from_realtime_lobby: true})
        verify(String(screen.source).endsWith("SeekScreen.qml"))
        screen.item.submitComputerGame()
        var computerRequest = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        endpoint.reply({type: "GameStarted", game_id: "external-ai", from_realtime_lobby: false})
        endpoint.reply(boardState("external-ai"))
        verify(String(screen.source).endsWith("SeekScreen.qml"))
        endpoint.reply({type: "ComputerGameCreated", game_id: "requested", request_id: computerRequest})
        verify(String(screen.source).endsWith("BoardScreen.qml"))
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "ResumeGame", game_id: "requested"})
        endpoint.reply(boardState("previous"))
        compare(screen.item.gameId, "")
        endpoint.reply(boardState("requested"))
        compare(screen.item.gameId, "requested")
    }

    function test_onlyAnActionReplyForThisBoardChangesItsState() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("active")
        endpoint.reply(boardState("active"))
        screen.item.requestGameAction({type: "AddTime", seconds: 15}, "AddTime")
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.expected_game_id, "active")
        verify(request.request_id > 0)

        endpoint.reply({type: "GameActionCompleted", game_id: "previous", action: "AddTime",
                        request_id: request.request_id, seconds: 15})
        compare(screen.item.pendingGameAction, "AddTime")
        compare(screen.item.statusText, "")
        endpoint.reply({type: "OpponentGone", game_id: "previous", gone: true})
        verify(!screen.item.opponentGone)
        endpoint.reply({type: "MoveRejected", game_id: "previous", reason: "old move"})
        compare(screen.item.statusText, "")

        endpoint.reply({type: "GameActionFailed", game_id: "active", action: "AddTime",
                        request_id: request.request_id, message: "try again"})
        compare(screen.item.pendingGameAction, "")
        compare(screen.item.statusText, "try again")
    }

    function test_pendingBoardActionSurvivesReopenAndRejectsOldReplies() {
        app.openGame("active")
        var snapshot = boardState("active")
        endpoint.reply(snapshot)
        screen.item.requestGameAction({type: "AddTime", seconds: 30}, "AddTime")
        var first = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        verify(first > 0)
        app.navigateTo("HomeScreen.qml")
        app.openGame("active")
        snapshot.pending_game_action = {action: "AddTime", request_id: first, seconds: 30}
        endpoint.reply(snapshot)
        compare(screen.item.gameActionsLabel(), "Working...")
        var messageCount = endpoint.sentMessages.length
        screen.item.requestGameAction({type: "AddTime", seconds: 30}, "AddTime")
        compare(endpoint.sentMessages.length, messageCount)

        endpoint.reply({type: "GameActionCompleted", game_id: "active", action: "AddTime",
                        request_id: first, seconds: 30})
        compare(screen.item.gameActionsLabel(), "Actions")
        compare(screen.item.statusText, "30 seconds added to opponent")
        screen.item.requestGameAction({type: "AddTime", seconds: 15}, "AddTime")
        var second = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        verify(second > first)
        endpoint.reply({type: "GameActionFailed", game_id: "active", action: "AddTime",
                        request_id: first, message: "old error"})
        endpoint.reply({type: "GameActionCompleted", game_id: "active", action: "Berserk",
                        request_id: second})
        compare(screen.item.gameActionsLabel(), "Working...")
        compare(screen.item.statusText, "")

        endpoint.reply({type: "GameOver", game_id: "active", result: "draw", reason: "Agreement"})
        compare(screen.item.gameActionsLabel(), "Game over")
        endpoint.reply({type: "GameActionCompleted", game_id: "active", action: "AddTime",
                        request_id: second, seconds: 15})
        compare(screen.item.statusText, "Draw · Agreement")
    }

    function test_timeGiftConfirmationSurvivesClockAndOfferUpdates() {
        app.openGame("active")
        var snapshot = boardState("active")
        snapshot.can_give_time = true
        endpoint.reply(snapshot)
        var board = screen.item
        board.requestGameAction({type: "AddTime", seconds: 15}, "AddTime")
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        endpoint.reply({type: "GameActionCompleted", game_id: "active", action: "AddTime",
                        request_id: request.request_id, seconds: 15})
        snapshot.black_time_ms += 15000
        snapshot.draw_offered_by_opponent = true
        endpoint.reply(snapshot)
        compare(board.blackTimeMs, 615000)
        compare(board.topStatusText(), "15 seconds added to opponent")
        compare(board.gameActionsLabel(), "Draw offer")

        snapshot.fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        snapshot.turn = "black"
        snapshot.position_history = [startFen, snapshot.fen]
        snapshot.move_history = ["e4"]
        endpoint.reply(snapshot)
        compare(board.topStatusText(), "Waiting for opponent")

        endpoint.reply({type: "ErrorMsg", message: "Temporary board error"})
        compare(board.topStatusText(), "Temporary board error")
        endpoint.reply(snapshot)
        compare(board.topStatusText(), "Waiting for opponent")
    }

    function showPendingMovePreview(whiteClock) {
        verify(screen.item.submitMove("e2", "e4", null))
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        var preview = {
            type: "MovePreview", game_id: "active", request_id: request.request_id,
            fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            turn: "black", last_move: ["e2", "e4"],
            white_time_ms: whiteClock === undefined ? 597000 : whiteClock, black_time_ms: 600000
        }
        endpoint.reply(preview)
        return preview
    }

    function test_previewAndRollbackEachUseTheirOwnClockAge_data() {
        return [{tag: "running main clock", paused: false},
                {tag: "paused main clock with first move deadline", paused: true}]
    }

    function test_previewAndRollbackEachUseTheirOwnClockAge(data) {
        app.openGame("active")
        var snapshot = boardState("active")
        if (data.paused) snapshot.first_move_time_ms = 14000
        snapshot.initial_clock_ms = 600000
        endpoint.reply(snapshot)
        var board = screen.item
        var predictedWhite = data.paused ? 600000 : 597000
        var preview = showPendingMovePreview(predictedWhite)
        var previewAt = board.previewClock.receivedAt
        compare(board.displayFirstMoveTimeMs(), null)

        endpoint.reply({type: "GameStreamReconnecting", game_id: "active"})
        snapshot.white_time_ms = data.paused ? 600000 : 599000
        if (data.paused) snapshot.first_move_time_ms = 13000
        snapshot.game_stream_connected = true
        endpoint.reply(snapshot)
        var liveAt = board.liveClock.receivedAt
        board.clockNowMs = Math.max(previewAt, liveAt) + 2000
        compare(board.fen, preview.fen)
        compare(board.whiteTimeMs, predictedWhite)
        var previewAge = Math.floor((board.clockNowMs - previewAt) / 1000) * 1000
        compare(board.displayClockFor("black"), 600000 - (data.paused ? 0 : previewAge))
        compare(board.displayFirstMoveTimeMs(), null)
        compare(board.topStatusText(), "Submitting e2–e4")

        endpoint.reply({type: "MoveRejected", game_id: "active", request_id: preview.request_id,
                        reason: "try again"})
        compare(board.fen, startFen)
        compare(board.whiteTimeMs, snapshot.white_time_ms)
        compare(board.displayClockFor("white"), data.paused ? 600000 : 597000)
        compare(board.displayFirstMoveTimeMs(), data.paused ? 11000 : null)
        endpoint.reply(snapshot)
        compare(board.topStatusText(), "Move rejected: try again")
    }

    function test_liveClockTimerReachesCadenceBoundaryAfterResync_data() {
        return [
            {tag: "main clock at one minute", mainMs: 60400, firstMoveMs: null,
             before: "1:00", after: "0:59"},
            {tag: "main clock at fifteen seconds", mainMs: 15400, firstMoveMs: null,
             before: "0:15", after: "0:14"},
            {tag: "first move at fifteen seconds", mainMs: 600000, firstMoveMs: 15400,
             before: "Move in ~16s", after: "Move in ~15s"}
        ]
    }

    function test_liveClockTimerReachesCadenceBoundaryAfterResync(data) {
        app.openGame("active")
        var snapshot = boardState("active")
        snapshot.initial_clock_ms = 600000
        snapshot.white_time_ms = data.mainMs
        snapshot.first_move_time_ms = data.firstMoveMs
        endpoint.reply(snapshot)
        var board = screen.item
        var mainClock = data.firstMoveMs === null
        var bar = findChild(board, mainClock ? "bottomPlayerBar" : "topPlayerBar")
        var label = findChild(bar, mainClock ? "playerClockText" : "playerStatusText")
        verify(label.visible)
        compare(label.text, data.before)
        wait(650)
        endpoint.reply(snapshot)
        var pulse = board.clockPulse
        wait(550)
        compare(board.clockPulse, pulse)
        compare(label.text, data.before)
        tryCompare(label, "text", data.after, 2400)
        compare(board.displayClockFor("black"), 600000)

        snapshot.first_move_time_ms = null
        snapshot.outcome = {result: "draw", reason: "Agreement"}
        endpoint.reply(snapshot)
        verify(board.gameOver)
        pulse = board.clockPulse
        wait(1200)
        compare(board.clockPulse, pulse)
    }

    function test_mainClockStartsOnlyAfterTheAuthoritativeOpeningUpdate() {
        app.openGame("active")
        var board = screen.item
        var afterWhite = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        var afterBlack = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var snapshot = Object.assign(boardState("active"), {
            fen: afterWhite, turn: "black", your_color: "black",
            position_history: [startFen, afterWhite], move_history: ["e4"],
            legal_moves: [{from: "e7", to: "e5"}], first_move_time_ms: 0, initial_clock_ms: 600000
        })
        endpoint.reply(snapshot)
        board.clockNowMs = board.liveClock.receivedAt + 3000
        compare(board.displayFirstMoveTimeMs(), 0)
        compare(board.displayClockFor("black"), 600000)
        verify(board.submitMove("e7", "e5", null))
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        var accepted = Object.assign({}, snapshot, {
            fen: afterBlack, turn: "white", position_history: [startFen, afterWhite, afterBlack],
            move_history: ["e4", "e5"], first_move_time_ms: null, main_clock_paused: true,
            last_move: ["e7", "e5"], resolved_move_request_id: request.request_id
        })
        endpoint.reply(accepted)
        board.clockNowMs = board.liveClock.receivedAt + 3000
        compare(board.fen, afterBlack)
        verify(board.mainClockPaused)
        compare(board.displayFirstMoveTimeMs(), null)
        compare(board.displayClockFor("white"), 600000)
        compare(board.displayClockFor("black"), 600000)

        endpoint.reply(Object.assign({}, accepted, {
            main_clock_paused: false, white_time_ms: 599000, resolved_move_request_id: null
        }))
        board.clockNowMs = board.liveClock.receivedAt + 2000
        verify(!board.mainClockPaused)
        compare(board.displayClockFor("white"), 597000)
        compare(board.displayClockFor("black"), 600000)
    }

    function test_authoritativeBoardAndOutcomeReplaceThePreviewClocks() {
        app.openGame("active")
        var snapshot = boardState("active")
        endpoint.reply(snapshot)
        var preview = showPendingMovePreview()
        snapshot.fen = preview.fen
        snapshot.turn = preview.turn
        snapshot.position_history = [startFen, snapshot.fen]
        snapshot.move_history = ["e4"]
        snapshot.white_time_ms = 598000
        snapshot.black_time_ms = 596000
        snapshot.resolved_move_request_id = preview.request_id
        endpoint.reply(snapshot)
        var board = screen.item
        compare(board.previewFen, "")
        compare(board.whiteTimeMs, 598000)
        compare(board.blackTimeMs, 596000)

        snapshot.outcome = {result: "draw", reason: "Agreement"}
        snapshot.black_time_ms = 591000
        endpoint.reply(snapshot)
        board.clockNowMs += 2000
        verify(board.gameOver)
        compare(board.displayClockFor("black"), 591000)
        compare(board.statusText, "Draw · Agreement")
    }

    function test_moveRepliesCannotAffectANewerSameGameSubmission() {
        app.openGame("active")
        endpoint.reply(boardState("active"))
        verify(screen.item.submitMove("e2", "e4", null))
        var first = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        var advanced = boardState("active")
        advanced.fen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        advanced.last_move = ["e7", "e5"]
        advanced.position_history = [startFen, advanced.fen]
        advanced.move_history = ["e4", "e5"]
        advanced.resolved_move_request_id = first
        endpoint.reply(advanced)

        verify(screen.item.submitMove("g1", "f3", null))
        var second = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        verify(second > first)
        var preview = {
            type: "MovePreview", game_id: "active", request_id: first,
            fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
            turn: "black", last_move: ["g1", "f3"], white_time_ms: 597000, black_time_ms: 598000
        }
        endpoint.reply(preview)
        compare(screen.item.previewFen, "")
        preview.request_id = second
        endpoint.reply(preview)
        compare(screen.item.fen, preview.fen)

        endpoint.reply({type: "MoveRejected", game_id: "active", request_id: first, reason: "late failure"})
        compare(screen.item.fen, preview.fen)
        compare(screen.item.topStatusText(), "Submitting g1–f3")
        verify(!screen.item.submitMove("d2", "d4", null))
        endpoint.reply({type: "MoveRejected", game_id: "active", request_id: second, reason: "try again"})
        compare(screen.item.fen, advanced.fen)
        compare(screen.item.statusText, "Move rejected: try again")

        app.navigateTo("HomeScreen.qml")
        app.openGame("active")
        endpoint.reply(advanced)
        verify(screen.item.submitMove("g1", "f3", null))
        var afterReopen = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        verify(afterReopen > second)
        endpoint.reply({type: "MoveRejected", game_id: "active", request_id: second, reason: "old visit"})
        compare(screen.item.topStatusText(), "Submitting g1–f3")
    }

    function test_backgroundBoardStateDoesNotReplaceTheSelectedBoard() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("active")
        endpoint.reply(boardState("active"))
        compare(screen.item.gameId, "active")

        var before = endpoint.sentMessages.length
        endpoint.reply({type: "GameStarted", game_id: "background", from_realtime_lobby: true})
        compare(endpoint.sentMessages.length, before)
        endpoint.reply(boardState("background"))
        compare(screen.item.gameId, "active")
    }

    function test_boardLoadingHasScopedStatusAndCanReturnHome() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("selected")
        var back = findChild(screen.item, "boardBackButton")
        var loadingStatus = findChild(screen.item, "boardLoadingStatus")
        verify(back.visible)
        verify(loadingStatus.visible)
        compare(loadingStatus.text, "Loading game...")
        compare(screen.item.activeTurnColor, "")

        endpoint.reply({type: "GameStreamReconnecting", game_id: "old"})
        compare(loadingStatus.text, "Loading game...")
        endpoint.reply({type: "GameStreamReconnecting", game_id: "selected"})
        compare(loadingStatus.text, "Reconnecting...")
        endpoint.reply({type: "GameStreamFailed", game_id: "old", message: "Wrong game"})
        compare(loadingStatus.text, "Reconnecting...")
        endpoint.reply({type: "GameStreamFailed", game_id: "selected", message: "Game unavailable"})
        compare(loadingStatus.text, "Game unavailable")
        verify(back.enabled)
        back.clicked()
        verify(String(screen.source).endsWith("HomeScreen.qml"))
        endpoint.reply(boardState("selected"))
        verify(String(screen.source).endsWith("HomeScreen.qml"))
    }

    function test_loadedBoardHidesBackUntilTheStreamIsRejected() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("selected")
        var back = findChild(screen.item, "boardBackButton")
        endpoint.reply(boardState("selected"))
        verify(!back.visible)
        var before = endpoint.sentMessages.length

        endpoint.reply({type: "GameStreamFailed", game_id: "selected", message: "Game unavailable"})
        verify(back.visible)
        compare(screen.item.activeTurnColor, "")
        screen.item.requestGameAction({type: "AddTime", seconds: 15}, "AddTime")
        compare(endpoint.sentMessages.length, before)
    }

    function test_cachedBoardCanRestoreItsReconnectStatus() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("selected")
        var snapshot = boardState("selected")
        snapshot.game_stream_connected = false
        endpoint.reply(snapshot)
        compare(screen.item.topStatusText(), "Reconnecting...")
        compare(screen.item.liveFen, snapshot.fen)

        snapshot.game_stream_connected = true
        endpoint.reply(snapshot)
        compare(screen.item.topStatusText(), "Your move")
    }

    function test_cachedOpponentDepartureRestoresClaimsAndRespectsTheServerCountdown() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("selected")
        var snapshot = boardState("selected")
        snapshot.game_stream_connected = true
        snapshot.opponent_departure = {claim_win_in_seconds: 12}
        endpoint.reply(snapshot)
        compare(screen.item.gameActionsLabel(), "Opponent left")
        screen.item.showGameActions = true
        var claim = findChild(screen.item, "claimVictoryButton")
        var draw = findChild(screen.item, "claimDrawAction")
        verify(claim.visible)
        verify(!claim.enabled)
        compare(claim.text, "Claim victory (~12s)")
        verify(!draw.visible)

        endpoint.reply({type: "OpponentGone", game_id: "other", gone: true,
                        claim_win_in_seconds: 0})
        verify(!claim.enabled)
        endpoint.reply({type: "OpponentGone", game_id: "selected", gone: true,
                        claim_win_in_seconds: 0})
        verify(claim.enabled)
        verify(draw.visible)
        endpoint.reply({type: "OpponentGone", game_id: "selected", gone: false})
        verify(!claim.visible)
        verify(!draw.visible)

        endpoint.reply({type: "OpponentGone", game_id: "selected", gone: true,
                        claim_win_in_seconds: 0})
        verify(claim.enabled)
        endpoint.reply({type: "GameStreamReconnecting", game_id: "selected"})
        verify(!claim.visible)
        verify(!draw.visible)
        snapshot.opponent_departure = null
        endpoint.reply(snapshot)
        verify(!claim.visible)
        verify(!draw.visible)

        snapshot.opponent_departure = {claim_win_in_seconds: 0}
        endpoint.reply(snapshot)
        verify(claim.enabled)
        snapshot.outcome = {result: "white", reason: "Opponent resigned"}
        endpoint.reply(snapshot)
        verify(!screen.item.opponentGone)
    }

    function test_seekIgnoresAnUnrelatedChallengeAndOpensItsMatch() {
        app.navigateTo("SeekScreen.qml")
        screen.item.submitSeek()
        endpoint.reply({type: "SeekCreated", request_id: screen.item.matchRequestId})
        verify(screen.item.waiting)
        endpoint.reply({type: "GameStarted", game_id: "challenge", from_realtime_lobby: false})
        verify(String(screen.source).endsWith("SeekScreen.qml"))
        endpoint.reply({type: "GameStarted", game_id: "pool-match", from_realtime_lobby: true})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "ResumeGame", game_id: "pool-match"})
        verify(String(screen.source).endsWith("BoardScreen.qml"))
    }

    function test_matchmakingCanBeCancelledBeforeAcknowledgement_data() {
        return [{tag: "seek", direct: false}, {tag: "direct challenge", direct: true}]
    }

    function test_matchmakingCanBeCancelledBeforeAcknowledgement(data) {
        app.navigateTo("SeekScreen.qml")
        var seek = screen.item
        var pager = findChild(seek, "seekFlickable")
        if (data.direct) pager.pageDown()
        function submit() {
            if (data.direct) {
                findChild(seek, "usernameField").text = "opponent"
                seek.submitChallenge()
            } else seek.submitSeek()
            return endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        }
        var first = submit()
        verify(first > 0)
        var cancel = findChild(seek, "cancelMatchButton")
        verify(cancel && cancel.visible && cancel.enabled)
        verify(!findChild(seek, "findOpponentButton").visible)
        tryVerify(function() {
            return cancel.mapToItem(pager, 0, 0).y >= 0 &&
                cancel.mapToItem(pager, 0, cancel.height).y <= pager.pageHeight
        })
        cancel.clicked()
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "CancelMatch", request_id: first})
        compare(seek.pendingAction, "")
        verify(seek.showingSetup)

        var second = submit()
        verify(first !== second)
        var createdType = data.direct ? "ChallengeCreated" : "SeekCreated"
        var failedType = data.direct ? "ChallengeCreateFailed" : "SeekFailed"
        endpoint.reply({type: createdType, game_id: "previous", request_id: first})
        endpoint.reply({type: failedType, request_id: first, message: "Old failure"})
        verify(!seek.waiting)
        compare(seek.formError, "")
        endpoint.reply({type: createdType, game_id: "current", request_id: second})
        verify(seek.waiting)
    }

    function test_seekMatchBeforeTheAckWaitsForSuccess() {
        app.navigateTo("SeekScreen.qml")
        screen.item.submitSeek()
        endpoint.reply({type: "GameStarted", game_id: "old-match", from_realtime_lobby: true})
        verify(String(screen.source).endsWith("SeekScreen.qml"))
        endpoint.reply({type: "SeekFailed", request_id: screen.item.matchRequestId,
                        message: "Could not create seek"})
        verify(String(screen.source).endsWith("SeekScreen.qml"))

        screen.item.submitSeek()
        endpoint.reply({type: "GameStarted", game_id: "new-match", from_realtime_lobby: true})
        endpoint.reply({type: "SeekCreated", request_id: screen.item.matchRequestId})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "ResumeGame", game_id: "new-match"})
    }

    function test_seekEndsAndCanBeRestartedWithoutAStaleReply() {
        app.navigateTo("SeekScreen.qml")
        screen.item.submitSeek()
        var first = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        endpoint.reply({type: "SeekCreated", request_id: first})
        endpoint.reply({type: "SeekEnded", request_id: first})
        compare(screen.item.waitingLabel, "Checking for a match...")
        tryCompare(screen.item, "waiting", false, 6500)
        verify(findChild(screen.item, "seekEndedNotice").visible)
        var pager = findChild(screen.item, "seekFlickable")
        var retry = findChild(screen.item, "findOpponentButton")
        tryVerify(function() { return retry.mapToItem(pager, 0, retry.height).y <= pager.pageHeight })
        compare(retry.text, "Search again")
        verify(findChild(screen.item, "editSeekSetupButton").visible)

        retry.clicked()
        var second = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        verify(first !== second)
        endpoint.reply({type: "SeekCreated", request_id: second})
        endpoint.reply({type: "SeekEnded", request_id: first})
        compare(screen.item.waitingLabel, "Waiting for an opponent...")
        verify(screen.item.waiting)
    }

    function test_seekCanOpenAMatchAnnouncedAfterTheConnectionCloses() {
        app.navigateTo("SeekScreen.qml")
        screen.item.submitSeek()
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        endpoint.reply({type: "SeekCreated", request_id: request})
        endpoint.reply({type: "SeekEnded", request_id: request})
        compare(screen.item.waitingLabel, "Checking for a match...")
        endpoint.reply({type: "GameStarted", game_id: "late-match", from_realtime_lobby: true})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "ResumeGame", game_id: "late-match"})
    }

    function test_directChallengeOpensOnlyItsAcceptedGame() {
        app.navigateTo("SeekScreen.qml")
        findChild(screen.item, "usernameField").text = "opponent"
        screen.item.submitChallenge()
        var first = screen.item.matchRequestId
        endpoint.reply({type: "ChallengeCreated", game_id: "outgoing", request_id: first})
        endpoint.reply({type: "GameStarted", game_id: "outgoing", from_realtime_lobby: false})
        endpoint.reply({type: "GameStarted", game_id: "unrelated", from_realtime_lobby: true})
        endpoint.reply({type: "ChallengeResolved", game_id: "previous", request_id: first,
                        error: "Old challenge"})
        verify(screen.item.waiting)
        endpoint.reply({type: "ChallengeResolved", game_id: "outgoing", request_id: first,
                        error: "Challenge declined."})
        compare(screen.item.formError, "Challenge declined.")
        verify(!screen.item.waiting)

        screen.item.submitChallenge()
        var second = screen.item.matchRequestId
        endpoint.reply({type: "ChallengeCreated", game_id: "accepted", request_id: second})
        endpoint.reply({type: "ChallengeResolved", game_id: "accepted", request_id: second, error: null})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "ResumeGame", game_id: "accepted"})
    }

    function test_openChallengeMatchesTheShareableLink() {
        app.navigateTo("SeekScreen.qml")
        screen.item.submitOpenChallenge()
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        endpoint.reply({type: "OpenChallengeCreated", game_id: "link",
                        request_id: request,
                        url: "https://lichess.org/game/link", url_white: "white", url_black: "black"})
        endpoint.reply({type: "GameStarted", game_id: "other", from_realtime_lobby: false})
        verify(String(screen.source).endsWith("SeekScreen.qml"))
        endpoint.reply({type: "GameStarted", game_id: "link", from_realtime_lobby: false})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "ResumeGame", game_id: "link"})
    }

    function test_matchCreationIsScopedAcrossVisits_data() {
        return [{tag: "computer", action: "computer", success: "ComputerGameCreated",
                 button: "computerGameButton", busyText: "Starting game…"},
                {tag: "open challenge", action: "open", success: "OpenChallengeCreated",
                 button: "openChallengeButton", busyText: "Creating link…"}]
    }

    function test_matchCreationIsScopedAcrossVisits(data) {
        function submit() {
            var seek = screen.item
            var button = findChild(seek, data.button)
            button.clicked()
            verify(!button.enabled)
            compare(button.text, data.busyText)
            var sent = endpoint.sentMessages.length
            seek.submitSeek()
            seek.submitComputerGame()
            seek.submitOpenChallenge()
            compare(endpoint.sentMessages.length, sent)
            return endpoint.sentMessages[sent - 1].request_id
        }
        app.navigateTo("SeekScreen.qml")
        var first = submit()
        var back = findChild(screen.item, "matchBackButton")
        verify(back.visible && back.enabled)
        verify(back.mapToItem(screen.item, 0, back.height).y <= screen.item.height)
        verify(!findChild(screen.item, "cancelMatchButton").visible)
        back.clicked()
        verify(String(screen.source).endsWith("HomeScreen.qml"))
        verify(endpoint.sentMessages.some(function(message) {
            return message.type === "CancelMatch" && message.request_id === first
        }))

        app.navigateTo("SeekScreen.qml")
        var second = submit()
        verify(second > first)
        endpoint.reply({type: data.success, game_id: "stale", request_id: first})
        endpoint.reply({type: "MatchCreationFailed", request_id: first, message: "old error"})
        verify(String(screen.source).endsWith("SeekScreen.qml"))
        compare(screen.item.pendingAction, data.action)
        compare(screen.item.formError, "")
        endpoint.reply({type: "MatchCreationFailed", request_id: second, message: "Try again"})
        compare(screen.item.formError, "Try again")
        compare(screen.item.pendingAction, "")
        var error = findChild(screen.item, "creationErrorText")
        verify(error.visible && error.text === "Try again")
        compare(error.mapToItem(screen.item, 0, error.height).y <
                findChild(screen.item, "matchBackButton").y, true)
        var third = submit()
        verify(third > second)
        endpoint.reply({type: data.success, game_id: "current", request_id: third,
                        url: "https://lichess.org/current", url_white: "white", url_black: "black"})
        if (data.action === "computer") {
            compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                    {type: "ResumeGame", game_id: "current"})
        } else {
            compare(screen.item.openChallengeUrls.game_id, "current")
            compare(screen.item.formError, "")
            compare(screen.item.pendingAction, "")
        }
    }

    function test_acceptChallengeWaitsForTheMatchingAcknowledgment() {
        app.navigateTo("HomeScreen.qml")
        screen.item.submitChallengeAction("accept", "incoming")
        var requestId = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        endpoint.reply({type: "GameStarted", game_id: "incoming", from_realtime_lobby: false})
        endpoint.reply({type: "PendingChallenges", challenges: []})
        endpoint.reply({type: "ChallengeAccepted", game_id: "previous", request_id: requestId})
        compare(screen.item.pendingChallengeId, "incoming")
        endpoint.reply({type: "ChallengeAccepted", game_id: "incoming", request_id: requestId})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "ResumeGame", game_id: "incoming"})
        verify(String(screen.source).endsWith("BoardScreen.qml"))
    }

    function test_declineWaitsForItsReplyAndStaleListsCannotRestoreTheRow() {
        app.navigateTo("HomeScreen.qml")
        var incoming = [{id: "target", challenger: "Target", limit_seconds: 600, increment_seconds: 0},
                        {id: "other", challenger: "Other", limit_seconds: 600, increment_seconds: 0}]
        var stale = {type: "PendingChallenges", challenges: incoming}
        endpoint.reply(stale)
        screen.item.submitChallengeAction("decline", "target")
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        endpoint.reply(stale)
        compare(screen.item.pendingChallengeId, "target")

        endpoint.reply({type: "ChallengeDeclined", challenge_id: "target", request_id: request.request_id})
        compare(screen.item.pendingChallengeId, "")
        compare(screen.item.pendingChallenges.length, 1)
        compare(screen.item.pendingChallenges[0].id, "other")

        app.navigateTo("GameHistoryScreen.qml")
        app.navigateTo("HomeScreen.qml")
        endpoint.reply(stale)
        compare(screen.item.pendingChallenges.length, 1)
        compare(screen.item.pendingChallenges[0].id, "other")
        endpoint.reply({type: "PendingChallenges", challenges: [incoming[1]]})
        compare(app.resolvedChallengeIds.length, 0)
    }

    function test_challengeFailureOnlyMatchesTheCurrentRequestForThatId() {
        app.navigateTo("HomeScreen.qml")
        screen.item.submitChallengeAction("accept", "same-id")
        var oldRequest = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        endpoint.reply({type: "ChallengeActionFailed", challenge_id: "same-id", request_id: oldRequest,
                        message: "Try again"})
        compare(screen.item.actionError, "Try again")
        screen.item.submitChallengeAction("accept", "same-id")
        var currentRequest = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        verify(oldRequest !== currentRequest)

        endpoint.reply({type: "ChallengeActionFailed", challenge_id: "same-id", request_id: oldRequest,
                        message: "Old error"})
        compare(screen.item.pendingChallengeId, "same-id")
        compare(screen.item.actionError, "")
        endpoint.reply({type: "ChallengeActionFailed", challenge_id: "same-id", request_id: currentRequest,
                        message: "Challenge expired"})
        compare(screen.item.pendingChallengeId, "")
        compare(screen.item.actionError, "Challenge expired")
    }

    function test_pendingAcceptSurvivesHomeRemountWithoutOpeningTheBoard() {
        app.navigateTo("HomeScreen.qml")
        var incoming = {id: "accepted-later", challenger: "Player"}
        endpoint.reply({type: "PendingChallenges", challenges: [incoming]})
        screen.item.submitChallengeAction("accept", incoming.id)
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        app.navigateTo("SettingsScreen.qml")
        app.navigateTo("HomeScreen.qml")
        compare(screen.item.pendingChallengeId, incoming.id)
        verify(findChild(screen.item, "pendingInvitationStatus").visible)
        endpoint.reply({type: "HomeState", request_id: latestHomeRequest(), ongoing_games: []})
        endpoint.reply({type: "PendingChallenges", challenges: [incoming]})
        var sent = endpoint.sentMessages.length
        screen.item.submitChallengeAction("decline", incoming.id)
        compare(endpoint.sentMessages.length, sent)

        endpoint.reply({type: "ChallengeDeclined", challenge_id: incoming.id, request_id: request})
        compare(screen.item.pendingChallengeId, incoming.id)
        compare(screen.item.pendingChallenges.length, 1)
        endpoint.reply({type: "ChallengeAccepted", game_id: incoming.id, request_id: request})
        verify(String(screen.source).endsWith("HomeScreen.qml"))
        compare(screen.item.pendingChallengeId, "")
        compare(screen.item.pendingChallenges.length, 0)
        tryVerify(function() { return endpoint.sentMessages.length === sent + 1 })
        compare(endpoint.sentMessages[sent].type, "RequestHome")
        verify(endpoint.sentMessages[sent].games_only)
        endpoint.reply({type: "HomeState", request_id: endpoint.sentMessages[sent].request_id,
                        ongoing_games: [{game_id: incoming.id, is_my_turn: true}]})
        compare(screen.item.ongoingGames[0].game_id, incoming.id)
        endpoint.reply({type: "PendingChallenges", challenges: [incoming]})
        compare(screen.item.pendingChallenges.length, 0)
    }

    function test_lateInvitationReplyRespectsSettingsAndSignOut() {
        app.navigateTo("HomeScreen.qml")
        screen.item.submitChallengeAction("accept", "background")
        var first = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        app.navigateTo("SettingsScreen.qml")
        endpoint.reply({type: "ChallengeAccepted", game_id: "background", request_id: first})
        verify(String(screen.source).endsWith("SettingsScreen.qml"))
        compare(app.pendingInvitation, null)

        app.navigateTo("HomeScreen.qml")
        screen.item.submitChallengeAction("decline", "prior-account")
        var second = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        endpoint.reply({type: "AuthenticationRequired"})
        endpoint.reply({type: "ChallengeDeclined", challenge_id: "prior-account", request_id: second})
        verify(String(screen.source).endsWith("LoginScreen.qml"))
        endpoint.reply({type: "TokenVerified", username: "different"})
        endpoint.reply({type: "ChallengeDeclined", challenge_id: "prior-account", request_id: second})
        compare(screen.item.pendingChallengeId, "")
        compare(app.resolvedChallengeIds.length, 0)
    }

    function test_startupRetryKeepsTheSavedSignInFlow() {
        var unverified = createTemporaryObject(Qt.createComponent("../ui/main.qml"), this)
        verify(unverified)
        var authEndpoint = findChild(unverified, "testAppLoadEndpoint")
        var startup = findChild(unverified, "screenLoader")
        var connectivityBar = findChild(unverified, "connectivityBar")
        verify(!connectivityBar.visible)
        compare(connectivityBar.height, 0)
        authEndpoint.reply({type: "AuthenticationCheckFailed", message: "Lichess is unavailable"})
        verify(String(startup.source).endsWith("StartupScreen.qml"))
        compare(startup.item.checkError, "Lichess is unavailable")
        verify(!connectivityBar.visible)
        compare(authEndpoint.sentMessages.length, 0)

        var retry = findChild(startup.item, "retryAuthenticationButton")
        verify(retry.visible)
        retry.clicked()
        compare(authEndpoint.sentMessages.length, 1)
        compare(authEndpoint.sentMessages[0].type, "RetryAuthentication")
        compare(startup.item.checkError, "")
        verify(!retry.visible)

        authEndpoint.reply({type: "TokenVerified", username: "player"})
        verify(String(startup.source).endsWith("HomeScreen.qml"))
        verify(connectivityBar.visible)
        authEndpoint.reply({type: "AuthenticationCheckFailed", message: "old error"})
        verify(String(startup.source).endsWith("HomeScreen.qml"))
    }

    function test_onlyTheCurrentSignInCanBeCommitted() {
        endpoint.reply({type: "AuthenticationRequired"})
        var login = screen.item
        var qr = login.signInRequestId
        verify(qr > 0)
        endpoint.reply({type: "LoginChallenge", request_id: qr, qr_size: 1, qr_rows: ["1"]})
        endpoint.reply({type: "LoginVerifying", request_id: qr})
        login.showManualEntry()
        var count = endpoint.sentMessages.length
        endpoint.reply({type: "LoginCompleted"})
        endpoint.reply({type: "SignInReady", request_id: qr})
        compare(endpoint.sentMessages.length, count)
        verify(login.manualEntry)

        findChild(login, "tokenField").text = "synthetic-fixture-token"
        login.saveToken()
        var manual = login.signInRequestId
        verify(manual > qr)
        endpoint.reply({type: "SignInReady", request_id: manual})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "CompleteSignIn", request_id: manual})
        endpoint.reply({type: "TokenVerified", username: "old", request_id: qr})
        verify(String(screen.source).endsWith("LoginScreen.qml"))
        endpoint.reply({type: "TokenVerified", username: "player", request_id: manual})
        verify(String(screen.source).endsWith("HomeScreen.qml"))
        compare(app.username, "player")
    }

    function test_logoutDiscardsOldGameRepliesAndClearsAccountData() {
        var abandoned = choose("private-game")
        app.username = "previous-player"
        app.reviewGame = {game_id: "previous-review"}
        app.reviewMoves = ["d4"]
        app.reviewFens = [startFen]

        endpoint.reply({type: "AuthenticationRequired"})
        endpoint.reply({type: "BoardState", game_id: "private-game", fen: startFen})
        replyWithMoves(abandoned, "e4")
        verify(String(screen.source).endsWith("LoginScreen.qml"))
        compare(app.username, "")
        compare(app.reviewGame, null)
        compare(app.reviewMoves.length, 0)
        compare(app.reviewFens.length, 0)
        compare(screen.item.errorMessage, "")
    }

    function test_finalBoardOpensWithTheLastMoveAndFrozenClocks() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("g1")
        var finalFen = "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3"
        var finalBoard = {
            type: "BoardState", game_id: "g1", fen: finalFen,
            turn: "white", your_color: "white", in_check: true,
            white_time_ms: 597000, black_time_ms: 598240, initial_clock_ms: 600000,
            last_move: ["d8", "h4"], legal_moves: [],
            move_history: ["f3", "e5", "g4", "Qh4#"],
            position_history: [startFen, finalFen],
            outcome: {result: "black", reason: "Checkmate"}
        }
        endpoint.reply(finalBoard)
        verify(String(screen.source).endsWith("BoardScreen.qml"))
        verify(screen.item.gameOver)
        compare(screen.item.fen, finalFen)
        compare(screen.item.lastMove, ["d8", "h4"])
        compare(screen.item.moveHistory[3], "Qh4#")
        compare(screen.item.displayClockFor("white"), 597000)
        compare(screen.item.displayClockFor("black"), 598240)
        verify(!findChild(screen.item, "topPlayerBar").active)
        verify(!findChild(screen.item, "bottomPlayerBar").active)
        verify(screen.item.canNavigateHome)

        endpoint.reply({type: "RatingDiff", game_id: "other", rating_diff: -12})
        compare(screen.item.statusText, "You lost · Checkmate")
        endpoint.reply({type: "RatingDiff", game_id: "g1", rating_diff: -5})
        compare(screen.item.statusText, "You lost · Checkmate · -5 rating")
        compare(findChild(screen.item, "gameOverSummary").text,
                "You lost · Checkmate · -5 rating")
        endpoint.reply({type: "RatingDiff", game_id: "g1", rating_diff: -5})
        compare(screen.item.statusText, "You lost · Checkmate · -5 rating")
        endpoint.reply({type: "BoardState", game_id: "g1", fen: startFen})
        endpoint.reply({type: "MoveRejected", game_id: "g1", reason: "late HTTP reply"})
        verify(screen.item.gameOver)
        compare(screen.item.fen, finalFen)
        compare(screen.item.statusText, "You lost · Checkmate · -5 rating")
    }

    function test_terminalResultAndReasonReachGameOverAndReview_data() {
        return [
            {tag: "clock draw on first snapshot", route: "first", result: "draw",
                reason: "Time expired", summary: "Draw", reviewResult: "draw"},
            {tag: "disconnect draw during a game", route: "update", result: "draw",
                reason: "Disconnection", summary: "Draw", reviewResult: "draw"},
            {tag: "insufficient material draw in fallback", route: "fallback", result: "draw",
                reason: "Insufficient material", summary: "Draw", reviewResult: "draw"},
            {tag: "local missed-first-move loss", route: "first", result: "black",
                reason: "First move deadline missed", summary: "You lost", reviewResult: "loss"}
        ]
    }

    function test_terminalResultAndReasonReachGameOverAndReview(data) {
        app.navigateTo("HomeScreen.qml")
        app.openGame("finished")
        if (data.route !== "first") endpoint.reply(boardState("finished"))
        if (data.route === "fallback") {
            endpoint.reply({type: "GameOver", game_id: "finished",
                            result: data.result, reason: data.reason})
        } else {
            var finalBoard = boardState("finished")
            finalBoard.outcome = {result: data.result, reason: data.reason}
            endpoint.reply(finalBoard)
        }
        verify(screen.item.gameOver)
        compare(findChild(screen.item, "gameOverSummary").text, data.summary + " · " + data.reason)
        findChild(screen.item, "reviewFinishedGameButton").clicked()
        var review = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(review.type, "RequestGameMoves")
        endpoint.reply({type: "GameMoves", request_id: review.request_id, moves: [], fens: [startFen]})
        compare(screen.item.game.result, data.reviewResult)
        compare(screen.item.gameDetailsLabel(), data.reason)
    }

    function test_ratingBeforeFirstBoardSnapshot_data() {
        return [{tag: "first snapshot terminal", firstSnapshotFinished: true},
                {tag: "first snapshot active", firstSnapshotFinished: false}]
    }

    function test_ratingBeforeFirstBoardSnapshot(data) {
        app.navigateTo("HomeScreen.qml")
        app.openGame("selected")
        verify(screen.item.awaitingBoard)
        endpoint.reply({type: "RatingDiff", game_id: "selected", rating_diff: 7})
        endpoint.reply({type: "RatingDiff", game_id: "other", rating_diff: 90})
        compare(screen.item.topStatusText(), "Loading game...")

        var snapshot = boardState("selected")
        if (data.firstSnapshotFinished)
            snapshot.outcome = {result: "white", reason: "Opponent resigned"}
        endpoint.reply(snapshot)
        if (!data.firstSnapshotFinished) {
            compare(screen.item.statusText, "")
            endpoint.reply({type: "GameOver", game_id: "selected",
                            result: "white", reason: "Opponent resigned"})
        }
        verify(screen.item.gameOver)
        compare(screen.item.statusText, "You won · Opponent resigned · +7 rating")
        compare(findChild(screen.item, "gameOverSummary").text,
                "You won · Opponent resigned · +7 rating")

        app.navigateTo("HomeScreen.qml")
        app.openGame("different")
        endpoint.reply({type: "RatingDiff", game_id: "selected", rating_diff: 7})
        var nextSnapshot = boardState("different")
        nextSnapshot.outcome = {result: "draw", reason: "Draw"}
        endpoint.reply(nextSnapshot)
        compare(screen.item.statusText, "Draw")
    }

    function test_finishedSnapshotSuppliesRatingWhenTheAccountEventWasMissed() {
        app.navigateTo("HomeScreen.qml")
        endpoint.reply({type: "RatingDiff", game_id: "finished", rating_diff: -7})
        app.openGame("finished")
        var snapshot = boardState("finished")
        snapshot.your_color = "black"
        snapshot.outcome = {result: "white", reason: "Resignation", rating_diff: -7}
        endpoint.reply(snapshot)
        compare(screen.item.statusText, "You lost · Resignation · -7 rating")
        endpoint.reply({type: "RatingDiff", game_id: "finished", rating_diff: -7})
        compare(screen.item.statusText, "You lost · Resignation · -7 rating")
        findChild(screen.item, "reviewFinishedGameButton").clicked()
        var review = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(review.type, "RequestGameMoves")
        endpoint.reply({type: "GameMoves", request_id: review.request_id, moves: [],
                        fens: [startFen]})
        verify(String(screen.source).endsWith("GameReviewScreen.qml"))
        compare(screen.item.game.rating_diff, -7)
    }

    function test_terminalSnapshotCanFillInAZeroRatingChange() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("finished")
        var snapshot = boardState("finished")
        snapshot.outcome = {result: "draw", reason: "Draw"}
        endpoint.reply(snapshot)
        compare(screen.item.statusText, "Draw")
        snapshot.outcome.rating_diff = 0
        endpoint.reply(snapshot)
        compare(screen.item.statusText, "Draw · 0 rating")
    }

    function test_reviewRating_data() {
        return [{tag: "event during export", source: "pending", expected: 0},
                {tag: "event after export", source: "loaded", expected: -7},
                {tag: "export only", source: "export", expected: 6}]
    }

    function test_reviewRating(data) {
        app.navigateTo("HomeScreen.qml")
        app.openGame("finished")
        var snapshot = boardState("finished")
        snapshot.outcome = {result: "draw", reason: "Draw"}
        endpoint.reply(snapshot)
        findChild(screen.item, "reviewFinishedGameButton").clicked()
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "RequestGameMoves")

        var rating = {type: "RatingDiff", game_id: "finished", rating_diff: data.expected}
        if (data.source === "pending") endpoint.reply(rating)
        endpoint.reply({type: "RatingDiff", game_id: "other", rating_diff: 90})
        var reply = {type: "GameMoves", request_id: request.request_id,
                     moves: ["e4"], fens: [startFen, startFen]}
        if (data.source === "export") reply.rating_diff = data.expected
        endpoint.reply(reply)
        verify(String(screen.source).endsWith("GameReviewScreen.qml"))
        var review = screen.item
        review.goNext()
        if (data.source === "loaded") {
            compare(review.game.rating_diff, null)
            endpoint.reply(rating)
        }
        endpoint.reply({type: "RatingDiff", game_id: "other", rating_diff: 91})
        compare(review.game.rating_diff, data.expected)
        compare(review.currentIndex, 1)
    }

    function test_playerStatusesReachOnlyTheSelectedBoardAndSurviveAnUpdate() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("selected")
        var snapshot = boardState("selected")
        snapshot.opponent_player = {id: "bob", name: "Bob"}
        endpoint.reply(snapshot)
        var playerBar = findChild(screen.item, "topPlayerBar")
        var title = findChild(playerBar, "playerTitleText")
        var profile = findChild(playerBar, "playerProfileText")
        var statuses = {type: "PlayerStatuses", game_id: "other",
                        players: [{id: "bob", title: "GM", online: true, patron: true}]}
        endpoint.reply(statuses)
        compare(title.text, "")
        verify(profile.text.indexOf("Patron") === -1)

        statuses.game_id = "selected"
        endpoint.reply(statuses)
        compare(title.text, "GM")
        verify(profile.text.indexOf("Patron") !== -1)
        endpoint.reply(snapshot)
        compare(title.text, "GM")
        verify(profile.text.indexOf("Patron") !== -1)
    }

    function test_tabletPlayerBarKeepsTheRatingVisibleWhenTheNameIsWide() {
        app.navigateTo("HomeScreen.qml")
        app.openGame("selected")
        var snapshot = boardState("selected")
        snapshot.your_player = {id: "player", rating: 1800}
        snapshot.opponent_player = {id: "bob", name: "WWWWWWWWWWWWWWWWWWWW",
                                    title: "GM", rating: 2700, provisional: true}
        snapshot.captured_by_black = ["wQ", "wR"]
        snapshot.initial_clock_ms = 600000
        endpoint.reply(snapshot)
        endpoint.reply({type: "PlayerStatuses", game_id: "selected",
                        players: [{id: "bob", online: true, playing: true,
                                   streaming: true, patron: true}]})

        var board = screen.item
        var bar = findChild(board, "topPlayerBar")
        var name = findChild(bar, "playerNameText")
        var rating = findChild(bar, "playerRatingText")
        var profile = findChild(bar, "playerProfileText")
        verify(rating !== null)
        tryCompare(name, "truncated", true)
        compare(rating.text, "(2700?)")
        verify(!rating.truncated)
        verify(rating.x + rating.width <= rating.parent.width)
        verify(!profile.truncated)
        verify(profile.text.indexOf("Patron") !== -1)

        board.manualFlip = true
        var bottomBar = findChild(board, "bottomPlayerBar")
        compare(findChild(bottomBar, "playerRatingText").text, "(2700?)")
        compare(rating.text, "(1800)")

        snapshot.outcome = {result: "draw", reason: "Draw"}
        endpoint.reply(snapshot)
        var finalProfile = findChild(bottomBar, "playerProfileText")
        verify(finalProfile.text.indexOf("Playing") === -1)
        verify(finalProfile.text.indexOf("Patron") !== -1)
    }
}
