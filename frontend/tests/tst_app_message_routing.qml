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

    function test_latestSelectionGetsItsOwnReplayAndHeader() {
        var first = choose("first")
        var messageCount = endpoint.sentMessages.length
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

    function test_backCancelsAndReopeningSameGameUsesADifferentRequest() {
        var abandoned = choose("same")
        app.navigateTo("HomeScreen.qml")
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
        var request = choose("custom-start")
        var base = "4k3/4p3/8/8/8/8/P7/4K3 b - - 0 17"
        var afterBlack = "4k3/8/8/4p3/8/8/P7/4K3 w - - 0 18"
        var afterWhite = "4k3/8/8/4p3/P7/8/8/4K3 b - - 0 18"
        endpoint.reply({type: "GameMoves", request_id: request,
                        moves: ["e5", "a4"], fens: [base, afterBlack, afterWhite]})
        verify(String(screen.source).endsWith("GameReviewScreen.qml"))
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
        endpoint.reply(boardState("background"))
        verify(String(screen.source).endsWith("GameHistoryScreen.qml"))
        verify(screen.item.openingReview)

        app.navigateTo("SeekScreen.qml")
        endpoint.reply(boardState("background"))
        verify(String(screen.source).endsWith("SeekScreen.qml"))
        screen.item.submitComputerGame()
        verify(screen.item.awaitingGame)
        endpoint.reply(boardState("requested"))
        verify(String(screen.source).endsWith("BoardScreen.qml"))
        compare(screen.item.gameId, "requested")
    }

    function test_onlyAnActionReplyForThisBoardChangesItsState() {
        app.navigateTo("HomeScreen.qml")
        app.expectNextGame("active")
        endpoint.reply(boardState("active"))
        screen.item.requestGameAction({type: "AddTime", seconds: 15}, "AddTime")
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.expected_game_id, "active")

        endpoint.reply({type: "GameActionCompleted", game_id: "previous", action: "AddTime"})
        compare(screen.item.pendingGameAction, "AddTime")
        compare(screen.item.statusText, "")
        endpoint.reply({type: "OpponentGone", game_id: "previous", gone: true})
        verify(!screen.item.opponentGone)
        endpoint.reply({type: "MoveRejected", game_id: "previous", reason: "old move"})
        compare(screen.item.statusText, "")

        endpoint.reply({type: "GameActionFailed", game_id: "active", action: "AddTime", message: "try again"})
        compare(screen.item.pendingGameAction, "")
        compare(screen.item.statusText, "try again")
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
        app.expectNextGame("g1")
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
        endpoint.reply({type: "BoardState", game_id: "g1", fen: startFen})
        endpoint.reply({type: "MoveRejected", game_id: "g1", reason: "late HTTP reply"})
        verify(screen.item.gameOver)
        compare(screen.item.fen, finalFen)
        compare(screen.item.statusText, "You lost · Checkmate · -5 rating")
    }
}
