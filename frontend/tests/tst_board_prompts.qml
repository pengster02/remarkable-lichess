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

    function test_offerButtonsSendTheDisplayedIntent_data() {
        return [
            {tag: "offer draw", action: "Draw", intent: "offer", flag: "can_offer_draw",
                control: "drawOfferAction", confirm: true, accept: true},
            {tag: "accept draw", action: "Draw", intent: "accept", flag: "draw_offered_by_opponent",
                control: "acceptDrawAction", confirm: true, accept: true},
            {tag: "decline draw", action: "Draw", intent: "decline", flag: "draw_offered_by_opponent",
                control: "declineDrawButton", confirm: false, accept: false},
            {tag: "offer takeback", action: "Takeback", intent: "offer", flag: "can_offer_takeback",
                control: "offerTakebackButton", confirm: false, accept: true},
            {tag: "accept takeback", action: "Takeback", intent: "accept", flag: "takeback_offered_by_opponent",
                control: "acceptTakebackButton", confirm: false, accept: true},
            {tag: "decline takeback", action: "Takeback", intent: "decline", flag: "takeback_offered_by_opponent",
                control: "declineTakebackButton", confirm: false, accept: false},
            {tag: "cancel own takeback", action: "Takeback", intent: "cancel", flag: "takeback_offered_by_you",
                control: "cancelTakebackButton", confirm: false, accept: false}
        ]
    }

    function test_offerButtonsSendTheDisplayedIntent(row) {
        var snapshot = state([start, afterE4, afterE5], ["e4", "e5"], "white")
        snapshot.position_id = 42
        snapshot[row.flag] = true
        endpoint.reply(snapshot)
        board.showGameActions = true
        var control = findChild(board, row.control)
        verify(control && control.visible)
        var button = row.confirm ? findChild(control, "confirmActionPrimary") : control
        var count = endpoint.sentMessages.length
        button.clicked()
        if (row.confirm) {
            compare(endpoint.sentMessages.length, count)
            button.clicked()
        }
        compare(endpoint.sentMessages.length, count + 1)
        var request = endpoint.sentMessages[count]
        compare(request.type, row.action + "Action")
        compare(request.expected_game_id, "selected")
        compare(request.expected_position_id, 42)
        compare(request.offer_intent, row.intent)
        compare(request.accept, row.accept)
        endpoint.reply({type: "GameActionFailed", game_id: "selected", action: row.action,
                        request_id: request.request_id, message: "Offer changed."})
        compare(board.pendingGameAction, "")
        compare(board.topStatusText(), "Offer changed.")
    }

    function test_reconnectDisarmsAnOldDrawConfirmation() {
        var snapshot = state([start, afterE4, afterE5], ["e4", "e5"], "white")
        snapshot.position_id = 42
        snapshot.draw_offered_by_opponent = true
        endpoint.reply(snapshot)
        board.showGameActions = true
        var control = findChild(board, "acceptDrawAction")
        var button = findChild(control, "confirmActionPrimary")
        button.clicked()
        compare(button.text, "Confirm draw")

        endpoint.reply({type: "GameStreamReconnecting", game_id: "selected"})
        verify(!control.visible)
        compare(control.armLevel, 0)
        var count = endpoint.sentMessages.length
        board.requestOfferAction("Draw", "accept")
        compare(endpoint.sentMessages.length, count)

        snapshot.game_stream_connected = true
        endpoint.reply(snapshot)
        verify(control.visible)
        compare(button.text, "Accept draw")
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

    function test_cancelLivePromotion_data() {
        return [
            {tag: "without move confirmation", confirm: false},
            {tag: "with move confirmation", confirm: true}
        ]
    }

    function test_cancelLivePromotion(row) {
        var fen = "7k/P7/8/8/8/8/8/4K3 w - - 0 1"
        var snapshot = state([fen], [], "white")
        snapshot.position_id = 31
        snapshot.legal_moves = [{from: "a7", to: "a8", promotion: "n"},
                                {from: "a7", to: "a8", promotion: "q"}]
        endpoint.reply(snapshot)
        board.moveConfirmation = row.confirm
        board.onSquareTapped("a7")
        board.onSquareTapped("a8")
        var loader = findChild(board, "promotionLoader")
        var cancel = findChild(loader.item, "promotionCancelButton")
        verify(cancel && waitForRendering(cancel))
        mouseClick(cancel, cancel.width / 2, cancel.height / 2)
        compare(loader.item, null)
        compare(board.selectedSquare, "")
        compare(board.fen, fen)
        compare(board.positionHistory, [fen])
        compare(board.pendingMoveConfirmation, null)
        compare(sentMoves().length, 0)

        board.onSquareTapped("a7")
        board.onSquareTapped("a8")
        verify(loader.item !== null)
        loader.item.chosen("n")
        if (row.confirm) {
            compare(board.pendingMoveConfirmation.promotion, "n")
            compare(sentMoves().length, 0)
            board.confirmPendingMove()
        }
        compare(sentMoves().length, 1)
        compare(sentMoves()[0].promotion, "n")
        compare(sentMoves()[0].expected_position_id, 31)
    }

    function test_cancelPromotionKeepsThePreviousPremove() {
        var fen = "7k/P7/8/8/8/8/8/4K3 b - - 0 1"
        endpoint.reply(state([fen], [], "black"))
        board.premovesEnabled = true
        board.onSquareTapped("e1")
        board.onSquareTapped("f1")
        var queued = board.pendingPremove
        verify(queued !== null)

        board.onSquareTapped("a7")
        board.onSquareTapped("a8")
        var loader = findChild(board, "promotionLoader")
        var cancel = findChild(loader.item, "promotionCancelButton")
        verify(cancel && waitForRendering(cancel))
        mouseClick(cancel, cancel.width / 2, cancel.height / 2)
        compare(loader.item, null)
        compare(board.selectedSquare, "")
        verify(board.pendingPremove === queued)
        compare(sentMoves().length, 0)

        var after = state([fen, "6k1/P7/8/8/8/8/8/4K3 w - - 1 2"], ["Kg8"], "white")
        after.legal_moves = [{from: "e1", to: "f1", promotion: null}]
        endpoint.reply(after)
        compare(sentMoves().length, 1)
        compare(sentMoves()[0].from, "e1")
        compare(sentMoves()[0].to, "f1")
    }

    function test_promotionClosesWhenItsMoveBecomesUnavailable_data() {
        return [{tag: "end of game", gameOver: true},
                {tag: "premoves disabled", gameOver: false}]
    }

    function test_promotionClosesWhenItsMoveBecomesUnavailable(row) {
        var fen = "7k/P7/8/8/8/8/8/4K3 b - - 0 1"
        endpoint.reply(state([fen], [], "black"))
        board.premovesEnabled = true
        board.onSquareTapped("a7")
        board.onSquareTapped("a8")
        var loader = findChild(board, "promotionLoader")
        verify(loader.item !== null)
        if (row.gameOver) {
            endpoint.reply({type: "GameOver", game_id: "selected", result: "draw", reason: "Agreement"})
        } else {
            board.premovesEnabled = false
        }
        compare(loader.item, null)
        compare(board.pendingPremove, null)
        compare(sentMoves().length, 0)
    }

    function test_autoQueenStillPromotesWithoutOpeningThePicker() {
        var snapshot = state(["7k/P7/8/8/8/8/8/4K3 w - - 0 1"], [], "white")
        snapshot.legal_moves = [{from: "a7", to: "a8", promotion: "n"},
                                {from: "a7", to: "a8", promotion: "q"}]
        endpoint.reply(snapshot)
        board.autoQueenPromotion = true
        board.onSquareTapped("a7")
        board.onSquareTapped("a8")
        compare(board.pendingPromotion, null)
        compare(sentMoves().length, 1)
        compare(sentMoves()[0].promotion, "q")
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
