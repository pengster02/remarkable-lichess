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

    function test_startupRetryKeepsTheSavedSignInFlow() {
        var unverified = createTemporaryObject(Qt.createComponent("../ui/main.qml"), this)
        verify(unverified)
        var authEndpoint = findChild(unverified, "testAppLoadEndpoint")
        var startup = findChild(unverified, "screenLoader")
        authEndpoint.reply({type: "AuthenticationCheckFailed", message: "Lichess is unavailable"})
        verify(String(startup.source).endsWith("StartupScreen.qml"))
        compare(startup.item.checkError, "Lichess is unavailable")
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
        verify(screen.item.canNavigateHome)

        endpoint.reply({type: "RatingDiff", game_id: "other", rating_diff: -12})
        compare(screen.item.statusText, "You lost · Checkmate")
        endpoint.reply({type: "RatingDiff", game_id: "g1", rating_diff: -5})
        compare(screen.item.statusText, "You lost · Checkmate · -5 rating")
        endpoint.reply({type: "BoardState", game_id: "g1", fen: startFen})
        verify(screen.item.gameOver)
        compare(screen.item.fen, finalFen)
    }
}
