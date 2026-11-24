import QtQuick 2.5
import QtTest 1.2

TestCase {
    name: "ReviewRequestRouting"
    when: windowShown
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
}
