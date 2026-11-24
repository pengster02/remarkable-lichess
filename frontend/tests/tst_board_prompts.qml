import QtQuick 2.5
import QtTest 1.2

TestCase {
    name: "BoardPrompts"
    when: windowShown
    visible: true
    width: 954
    height: 1696

    readonly property string start: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    readonly property string afterE4: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
    readonly property string afterE5: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    readonly property string afterNf3: "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"
    readonly property string afterNc6: "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3"

    property var endpoint
    property var board

    function init() {
        var component = Qt.createComponent("../ui/main.qml")
        compare(component.status, Component.Ready, component.errorString())
        var app = createTemporaryObject(component, this)
        verify(app)
        endpoint = findChild(app, "testAppLoadEndpoint")
        endpoint.reply({type: "TokenVerified", username: "Player"})
        app.openGame("selected")
        board = findChild(app, "screenLoader").item
    }

    function state(positions, moves, turn) {
        return {
            type: "BoardState", game_id: "selected", fen: positions[positions.length - 1],
            your_color: "white", turn: turn, white_time_ms: 300000, black_time_ms: 300000,
            legal_moves: [], position_history: positions, move_history: moves
        }
    }

    function sentMoves() {
        return endpoint.sentMessages.filter(function(message) { return message.type === "MakeMove" })
    }

    function test_takebackClosesAStagedMoveButClockFramesKeepIt() {
        var before = state([start, afterE4, afterE5], ["e4", "e5"], "white")
        before.legal_moves = [{from: "g1", to: "f3", promotion: null}]
        endpoint.reply(before)
        board.moveConfirmation = true
        board.onSquareTapped("g1")
        board.onSquareTapped("f3")
        var loader = findChild(board, "moveConfirmationLoader")
        verify(loader.item !== null)
        before.white_time_ms = 299000
        endpoint.reply(before)
        verify(loader.item !== null)

        var after = state([start], [], "white")
        after.legal_moves = before.legal_moves
        endpoint.reply(after)
        compare(board.fen, start)
        compare(loader.item, null)
        compare(board.selectedSquare, "")
        board.confirmPendingMove()
        compare(sentMoves().length, 0)

        board.onSquareTapped("g1")
        board.onSquareTapped("f3")
        board.confirmPendingMove()
        compare(sentMoves().length, 1)
    }

    function test_drawClaimConfirmationFollowsEligibility() {
        var snapshot = state([start, afterE4, afterE5], ["e4", "e5"], "white")
        snapshot.opponent_departure = {claim_win_in_seconds: 0}
        endpoint.reply(snapshot)
        board.showGameActions = true
        var control = findChild(board, "claimDrawAction")
        var button = findChild(control, "confirmActionPrimary")
        verify(control.visible)
        button.clicked()
        compare(button.text, "Confirm draw claim")
        snapshot.black_time_ms = 298000
        endpoint.reply(snapshot)
        compare(button.text, "Confirm draw claim")

        endpoint.reply({type: "OpponentGone", game_id: "selected", gone: false})
        verify(!control.visible)
        endpoint.reply({type: "OpponentGone", game_id: "selected", gone: true,
                        claim_win_in_seconds: 0})
        verify(control.visible)
        compare(button.text, "Claim draw")
        button.clicked()
        endpoint.reply({type: "GameOver", game_id: "selected", result: "draw", reason: "Agreement"})
        verify(!control.visible)
        compare(control.armLevel, 0)
    }

    function test_newPositionIdForTheSameLineClosesAnOldDraft() {
        var snapshot = state([start], [], "white")
        snapshot.position_id = 4294967293
        snapshot.legal_moves = [{from: "e2", to: "e4", promotion: null}]
        endpoint.reply(snapshot)
        board.moveConfirmation = true
        board.onSquareTapped("e2")
        board.onSquareTapped("e4")
        verify(board.pendingMoveConfirmation !== null)
        var history = board.positionHistory
        endpoint.reply(snapshot)
        verify(board.pendingMoveConfirmation !== null)

        snapshot.position_id += 1
        endpoint.reply(snapshot)
        compare(board.pendingMoveConfirmation, null)
        verify(board.positionHistory === history)
        board.confirmPendingMove()
        compare(sentMoves().length, 0)

        board.onSquareTapped("e2")
        board.onSquareTapped("e4")
        board.confirmPendingMove()
        compare(sentMoves().length, 1)
        compare(sentMoves()[0].expected_position_id, 4294967294)
    }

    function test_opponentMoveClosesAnUnfinishedPremovePromotion() {
        var promotion = "7k/P7/8/8/8/8/8/4K3 b - - 0 1"
        endpoint.reply(state([promotion], [], "black"))
        board.premovesEnabled = true
        board.onSquareTapped("a7")
        board.onSquareTapped("a8")
        var loader = findChild(board, "promotionLoader")
        verify(loader.item !== null)
        verify(board.pendingPromotion.premove)

        var advanced = state([promotion, "6k1/P7/8/8/8/8/8/4K3 w - - 1 2"], ["Kg8"], "white")
        advanced.legal_moves = [{from: "a7", to: "a8", promotion: "n"},
                                {from: "a7", to: "a8", promotion: "q"}]
        endpoint.reply(advanced)
        compare(loader.item, null)
        compare(board.pendingPremove, null)
        compare(sentMoves().length, 0)

        board.onSquareTapped("a7")
        board.onSquareTapped("a8")
        verify(loader.item !== null)
        loader.item.chosen("n")
        compare(sentMoves().length, 1)
        compare(sentMoves()[0].promotion, "n")
    }

    function test_premoveNeedsTheNextPlyOnTheSameLine_data() {
        return [
            {tag: "incremental advance", append: true, full: false, send: true},
            {tag: "full reconnect advances one ply", append: false, full: true, send: true},
            {tag: "full takeback still permits same move", append: false, full: true, send: false}
        ]
    }

    function test_premoveNeedsTheNextPlyOnTheSameLine(row) {
        var line = [start, afterE4, afterE5, afterNf3]
        var moves = ["e4", "e5", "Nf3"]
        var before = state(line, moves, "black")
        before.position_id = 100
        endpoint.reply(before)
        board.premovesEnabled = true
        board.onSquareTapped("d2")
        board.onSquareTapped("d4")
        verify(board.pendingPremove !== null)
        before.black_time_ms = 299000
        endpoint.reply(before)
        verify(board.pendingPremove !== null)
        compare(sentMoves().length, 0)

        if (row.full) endpoint.reply({type: "GameStreamReconnecting", game_id: "selected"})
        var after = row.send
            ? state(line.concat([afterNc6]), moves.concat(["Nc6"]), "white")
            : state(line.slice(0, -1), moves.slice(0, -1), "white")
        after.position_id = 104
        after.legal_moves = [{from: "d2", to: "d4", promotion: null}]
        if (row.append) {
            delete after.position_history
            delete after.move_history
            after.appended_move = "Nc6"
        } else {
            after.game_stream_connected = true
        }
        endpoint.reply(after)
        compare(board.pendingPremove, null)
        compare(sentMoves().length, row.send ? 1 : 0)
        if (row.send) {
            compare(sentMoves()[0].to, "d4")
            compare(sentMoves()[0].expected_position_id, 104)
        }
    }
}
