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
        height = 1696
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

    function firstCoordinateLabel(container) {
        for (var i = 0; i < container.children.length; i += 1) {
            var child = container.children[i]
            if (typeof child.text === "string") return child
        }
        return null
    }

    function verifyBoardLabels(board, flipped) {
        var corner = findChild(board, flipped ? "boardSquare-h1" : "boardSquare-a8")
        var origin = corner.mapToItem(board, 0, 0)
        var files = findChild(board, "boardFileLabels")
        var ranks = findChild(board, "boardRankLabels")
        verify(files.visible && ranks.visible)
        var firstFile = firstCoordinateLabel(files)
        var firstRank = firstCoordinateLabel(ranks)
        verify(firstFile && firstRank)
        compare(firstFile.text, flipped ? "h" : "a")
        compare(firstRank.text, flipped ? "1" : "8")
        fuzzyCompare(firstFile.mapToItem(board, 0, 0).x, origin.x, 0.5)
        fuzzyCompare(firstRank.mapToItem(board, 0, 0).y, origin.y, 0.5)
        fuzzyCompare(firstFile.width, corner.width, 0.5)
        fuzzyCompare(firstRank.height, corner.height, 0.5)
        return origin.x
    }

    function test_liveBoardKeepsItsPositionAndHitTargetsWhenCoordinatesAreHidden_data() {
        return [
            {tag: "Paper Pro", width: 1620, height: 2160, flipped: false},
            {tag: "Paper Pro Move flipped", width: 954, height: 1696, flipped: true}
        ]
    }

    function test_liveBoardKeepsItsPositionAndHitTargetsWhenCoordinatesAreHidden(data) {
        width = data.width
        height = data.height
        app.openGame("active")
        var snapshot = boardState("active")
        snapshot.legal_moves = [{from: "e2", to: "e4"}]
        endpoint.reply(snapshot)
        var board = screen.item
        board.manualFlip = data.flipped
        verify(waitForRendering(board))
        var left = verifyBoardLabels(board, data.flipped)
        var from = findChild(board, "boardSquare-e2")
        var to = findChild(board, "boardSquare-e4")
        var squareSize = from.width
        if (data.flipped) {
            fuzzyCompare(left, 122, 0.5)
            fuzzyCompare(squareSize * 8, 786, 0.5)
        } else {
            fuzzyCompare(left + squareSize * 4, width / 2, 0.5)
        }

        var start = from.mapToItem(board, from.width / 2, from.height / 2)
        var end = to.mapToItem(board, to.width / 2, to.height / 2)
        app.setShowCoordinates(false)
        verify(!findChild(board, "boardFileLabels").visible)
        verify(!findChild(board, "boardRankLabels").visible)
        compare(from.mapToItem(board, from.width / 2, from.height / 2), start)
        compare(to.mapToItem(board, to.width / 2, to.height / 2), end)
        compare(from.width, squareSize)

        if (data.flipped) {
            mouseDrag(board, start.x, start.y, end.x - start.x, end.y - start.y)
        } else {
            mouseClick(board, start.x, start.y)
            compare(board.selectedSquare, "e2")
            mouseClick(board, end.x, end.y)
        }
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "MakeMove")
        compare(request.from, "e2")
        compare(request.to, "e4")
    }

    function test_reviewAndExploreShareTheCenteredGrid() {
        width = 1620
        height = 2160
        var requestId = choose("geometry")
        endpoint.reply({type: "GameMoves", request_id: requestId, fens: [startFen], moves: []})
        var review = screen.item
        verify(waitForRendering(review))
        var left = verifyBoardLabels(review, false)
        var from = findChild(review, "boardSquare-e2")
        fuzzyCompare(left + from.width * 4, width / 2, 0.5)

        review.manualFlip = true
        review.beginExploration()
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: startFen, fen: startFen,
                        legal_moves: [{from: "e2", to: "e4"}]})
        verify(review.exploreMode)
        fuzzyCompare(verifyBoardLabels(review, true), left, 0.5)
        from = findChild(review, "boardSquare-e2")
        var to = findChild(review, "boardSquare-e4")
        mouseClick(from, from.width / 2, from.height / 2)
        compare(review.selectedSquare, "e2")
        mouseClick(to, to.width / 2, to.height / 2)
        var move = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(move.type, "MakeAnalysisMove")
        compare(move.from, "e2")
        compare(move.to, "e4")
    }

    function test_replayAndExploreApplyBoardDisplayPreferences_data() {
        return [{tag: "saved before opening replay", beforeLoad: true},
                {tag: "received during replay", beforeLoad: false}]
    }

    function test_replayAndExploreApplyBoardDisplayPreferences(data) {
        var settings = {type: "SettingsState", show_coordinates: false, highlight_last_move: false}
        if (data.beforeLoad) endpoint.reply(settings)

        var afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        var afterE5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var requestId = choose("display-settings")
        endpoint.reply({type: "GameMoves", request_id: requestId,
                        fens: [startFen, afterE4], moves: ["e4"]})
        var review = screen.item
        verify(waitForRendering(review))
        var files = findChild(review, "boardFileLabels")
        var ranks = findChild(review, "boardRankLabels")
        var pawn = findChild(review, "boardSquare-e4")
        var squarePosition = pawn.mapToItem(review, 0, 0)
        review.goNext()
        verify(pawn.flashRefresh)
        if (!data.beforeLoad) {
            verify(files.visible && ranks.visible)
            verify(pawn.isLastMove)
            endpoint.reply(settings)
        }
        verify(!files.visible && !ranks.visible)
        verify(!pawn.isLastMove)
        verify(pawn.flashRefresh)
        compare(pawn.mapToItem(review, 0, 0), squarePosition)

        review.beginExploration()
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: afterE4, fen: afterE4,
                        legal_moves: [{from: "e7", to: "e5"}]})
        verify(review.requestExplorationMove("e7", "e5"))
        endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                        from_fen: afterE4, fen: afterE5, san: "e5", legal_moves: []})
        var candidate = findChild(review, "boardSquare-e5")
        var candidatePosition = candidate.mapToItem(review, 0, 0)
        compare(review.variationMoves, ["e5"])
        verify(!candidate.isLastMove)
        verify(!files.visible && !ranks.visible)

        endpoint.reply({type: "SettingsState", show_coordinates: true, highlight_last_move: true})
        verify(files.visible && ranks.visible)
        verify(candidate.isLastMove && findChild(review, "boardSquare-e7").isLastMove)
        compare(candidate.mapToItem(review, 0, 0), candidatePosition)
        compare(review.currentFen(), afterE5)
    }

    function test_exploreMinimalHighlightsOnlyChangesTheVisibleTargets() {
        endpoint.reply({type: "SettingsState", minimal_highlights: true})
        var requestId = choose("minimal-highlights")
        endpoint.reply({type: "GameMoves", request_id: requestId, fens: [startFen], moves: []})
        var review = screen.item
        review.beginExploration()
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: startFen, fen: startFen,
                        legal_moves: [{from: "e2", to: "e4"}]})
        verify(waitForRendering(review))
        var source = findChild(review, "boardSquare-e2")
        var destination = findChild(review, "boardSquare-e4")
        mouseClick(source, source.width / 2, source.height / 2)
        verify(source.isSelected && source.isHighlighted)
        verify(!destination.isLegalDestination && !destination.isHighlighted)
        endpoint.reply({type: "SettingsState", minimal_highlights: false})
        verify(destination.isLegalDestination && destination.isHighlighted)
        endpoint.reply({type: "SettingsState", minimal_highlights: true})
        verify(!destination.isLegalDestination && !destination.isHighlighted)
        mouseClick(destination, destination.width / 2, destination.height / 2)
        var move = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(move.type, "MakeAnalysisMove")
        compare(move.from, "e2")
        compare(move.to, "e4")
    }

    function test_candidateNotationKeepsTheArchiveNavigationAndBaseMoveNumbers() {
        width = 1620
        height = 2160
        var base = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 37"
        var archiveFen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 38"
        var candidateFen = "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 38"
        var requestId = choose("candidate-notation")
        endpoint.reply({type: "GameMoves", request_id: requestId,
                        fens: [base, archiveFen], moves: ["e5"]})
        var review = screen.item
        review.beginExploration()
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: base, fen: base, legal_moves: [{from: "c7", to: "c5"}]})
        verify(review.requestExplorationMove("c7", "c5"))
        endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                        from_fen: base, fen: candidateFen, san: "c5", legal_moves: []})
        verify(waitForRendering(review))

        var candidateRow = findChild(review, "candidateMoveRow")
        compare(candidateRow.moveNumber, 37)
        compare(candidateRow.whiteMove, null)
        compare(candidateRow.blackMove.san, "c5")
        verify(findChild(candidateRow, "blackMoveCell").isCurrent)
        verify(!findChild(candidateRow, "blackMoveMouseArea").enabled)

        var archiveRow = findChild(review, "archiveMoveRow")
        var archiveMove = findChild(archiveRow, "blackMoveCell")
        compare(archiveRow.moveNumber, 37)
        compare(archiveRow.blackMove.san, "e5")
        mouseClick(archiveMove, archiveMove.width / 2, archiveMove.height / 2)
        compare(review.currentIndex, 1)
        compare(review.variationMoves, [])
        compare(review.currentFen(), archiveFen)
        var rebase = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(rebase.type, "RequestAnalysisPosition")
        compare(rebase.fen, archiveFen)
        tryVerify(function() { return findChild(review, "candidateMoveRow") === null })
    }

    function test_liveMovesPagesWholeRowsWithActionsAlwaysAvailable_data() {
        return [
            {tag: "Paper Pro Move", width: 954, height: 1696},
            {tag: "Paper Pro", width: 1620, height: 2160}
        ]
    }

    function test_liveMovesPagesWholeRowsWithActionsAlwaysAvailable(data) {
        width = data.width
        height = data.height
        app.openGame("live-score-sheet")
        var snapshot = boardState("live-score-sheet")
        var boards = [
            "rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R b KQkq - ",
            "rnbqkb1r/pppppppp/5n2/8/8/5N2/PPPPPPPP/RNBQKB1R w KQkq - ",
            "rnbqkb1r/pppppppp/5n2/8/8/8/PPPPPPPP/RNBQKBNR b KQkq - ",
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - "
        ]
        var notation = ["Nf3", "Nf6", "Ng1", "Ng8"]
        for (var ply = 1; ply <= 64; ply++) {
            snapshot.move_history.push(notation[(ply - 1) % 4])
            snapshot.position_history.push(boards[(ply - 1) % 4] + ply + " " + (1 + Math.floor(ply / 2)))
        }
        snapshot.fen = snapshot.position_history[64]
        endpoint.reply(snapshot)
        var board = screen.item
        var open = findChild(board, "boardToolbar").children[1]
        var loader = findChild(board, "moveHistoryLoader")
        verify(waitForRendering(board))
        mouseClick(open, open.width / 2, open.height / 2)
        var dialog = loader.item
        var pager = findChild(dialog, "dialogPager")
        var close = findChild(dialog, "historyCloseButton")
        var goLive = findChild(dialog, "historyReturnToLiveButton")
        verify(!goLive.visible)
        tryVerify(function() { return pager.pageCount > 1 })
        var closeY = close.mapToItem(dialog, 0, 0).y
        verify(closeY >= 0 && closeY + close.height <= dialog.height)
        var rows = []
        function collectRows(item) {
            if (item.objectName === "liveMoveRow") rows.push(item)
            for (var i = 0; i < item.children.length; i++) collectRows(item.children[i])
        }
        collectRows(pager)
        compare(rows.length, 32)
        var previous = findChild(pager, "pageUpButton")
        var next = findChild(pager, "pageDownButton")
        tryCompare(pager, "currentPage", pager.pageCount)
        var lastY = rows[31].mapToItem(pager, 0, 0).y
        verify(lastY >= 0 && lastY + rows[31].height <= pager.pageHeight)
        var seen = {}
        for (var page = pager.pageCount; page >= 1; page--) {
            compare(pager.currentPage, page)
            compare(close.mapToItem(dialog, 0, 0).y, closeY)
            for (var row = 0; row < rows.length; row++) {
                var y = rows[row].mapToItem(pager, 0, 0).y
                if (y >= -0.5 && y + rows[row].height <= pager.pageHeight + 0.5)
                    seen[row] = true
            }
            if (page > 1) mouseClick(previous, previous.width / 2, previous.height / 2)
        }
        compare(Object.keys(seen).length, 32)
        var start = findChild(dialog, "historyStartingPositionButton")
        var startY = start.mapToItem(pager, 0, 0).y
        verify(startY >= 0 && startY + start.height <= pager.pageHeight)
        for (page = 1; page < pager.pageCount; page++) {
            mouseClick(next, next.width / 2, next.height / 2)
            compare(pager.currentPage, page + 1)
        }
        var lastWhite = findChild(rows[31], "whiteMoveCell")
        verify(findChild(rows[31], "blackMoveCell").isCurrent)
        mouseClick(lastWhite, lastWhite.width / 2, lastWhite.height / 2)
        tryCompare(loader, "item", null)
        verify(board.viewingHistory)
        compare(board.fen, snapshot.position_history[63])

        mouseClick(open, open.width / 2, open.height / 2)
        dialog = loader.item
        pager = findChild(dialog, "dialogPager")
        goLive = findChild(dialog, "historyReturnToLiveButton")
        verify(goLive.visible && !goLive.contentItem.truncated)
        previous = findChild(pager, "pageUpButton")
        tryVerify(function() { return previous.visible && previous.enabled })
        tryCompare(pager, "currentPage", pager.pageCount)
        mouseClick(previous, previous.width / 2, previous.height / 2)
        var manuallySelectedPage = pager.currentPage
        snapshot.white_time_ms -= 500
        endpoint.reply(snapshot)
        compare(loader.item, dialog)
        compare(pager.currentPage, manuallySelectedPage)
        compare(board.fen, snapshot.position_history[63])
        mouseClick(goLive, goLive.width / 2, goLive.height / 2)
        tryCompare(loader, "item", null)
        verify(!board.viewingHistory)
        compare(board.fen, snapshot.fen)

        mouseClick(open, open.width / 2, open.height / 2)
        dialog = loader.item
        pager = findChild(dialog, "dialogPager")
        tryVerify(function() { return pager.pageCount > 1 })
        tryCompare(pager, "currentPage", pager.pageCount)
        previous = findChild(pager, "pageUpButton")
        mouseClick(previous, previous.width / 2, previous.height / 2)
        var manualOffset = pager.contentY
        var nextFen = boards[0] + "65 33"
        endpoint.reply(Object.assign({}, snapshot, {
            fen: nextFen, turn: "black", last_move: ["g1", "f3"],
            move_history: null, position_history: null, appended_move: "Nf3"
        }))
        tryVerify(function() {
            rows = []
            collectRows(pager)
            return rows.length === 33
        })
        compare(board.fen, nextFen)
        compare(pager.contentY, manualOffset)
        close = findChild(dialog, "historyCloseButton")
        mouseClick(close, close.width / 2, close.height / 2)
        tryCompare(loader, "item", null)
        compare(board.fen, nextFen)
    }

    function test_liveMovesEmptyOrShortHistoryFitsWithoutPaging_data() {
        return [{tag: "empty", plies: 0}, {tag: "one move", plies: 1}]
    }

    function test_liveMovesEmptyOrShortHistoryFitsWithoutPaging(data) {
        app.openGame("short-score-sheet")
        var snapshot = boardState("short-score-sheet")
        if (data.plies > 0) {
            snapshot.fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
            snapshot.turn = "black"
            snapshot.move_history.push("e4")
            snapshot.position_history.push(snapshot.fen)
        }
        endpoint.reply(snapshot)
        var board = screen.item
        var open = findChild(board, "boardToolbar").children[1]
        var loader = findChild(board, "moveHistoryLoader")
        verify(waitForRendering(board))
        mouseClick(open, open.width / 2, open.height / 2)
        var pager = findChild(loader.item, "dialogPager")
        verify(waitForRendering(loader.item))
        compare(pager.pageCount, 1)
        verify(!pager.pagingNeeded)
        var row = findChild(pager, "liveMoveRow")
        var start = findChild(pager, "historyStartingPositionButton")
        compare(start.visible, data.plies > 0)
        if (data.plies > 0) {
            compare(row.whiteMove.san, "e4")
            verify(findChild(row, "whiteMoveCell").isCurrent)
        } else {
            compare(row, null)
        }
        var close = findChild(loader.item, "historyCloseButton")
        mouseClick(close, close.width / 2, close.height / 2)
        tryCompare(loader, "item", null)
    }

    function test_liveMovesOpensTheCustomStartWithoutSubmittingAMove_data() {
        return [
            {tag: "Paper Pro Move black", width: 954, height: 1696, side: "black"},
            {tag: "Paper Pro white", width: 1620, height: 2160, side: "white"}
        ]
    }

    function test_liveMovesOpensTheCustomStartWithoutSubmittingAMove(data) {
        width = data.width
        height = data.height
        var base = "rnbqkbnr/ppppp1pp/5p2/7Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2"
        var replyFen = "rnbqkbnr/ppppp2p/5pp1/7Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 0 3"
        var live = "rnbqkbnr/ppppp2p/5pp1/8/4P3/5Q2/PPPP1PPP/RNB1KBNR b KQkq - 1 3"
        app.openGame("live-custom-start")
        var snapshot = boardState("live-custom-start")
        snapshot.fen = live
        snapshot.turn = "black"
        snapshot.your_color = data.side
        snapshot.position_history = [base, replyFen, live]
        snapshot.move_history = ["g6", "Qf3"]
        snapshot.legal_moves = [{from: "b8", to: "c6"}]
        endpoint.reply(snapshot)
        var board = screen.item
        var open = findChild(board, "boardToolbar").children[1]
        var loader = findChild(board, "moveHistoryLoader")
        verify(waitForRendering(board))
        var requests = endpoint.sentMessages.length
        mouseClick(open, open.width / 2, open.height / 2)
        verify(waitForRendering(loader.item))
        var start = findChild(loader.item, "historyStartingPositionButton")
        verify(start.visible)
        mouseClick(start, start.width / 2, start.height / 2)
        tryCompare(loader, "item", null)
        compare(board.fen, base)
        compare(board.historyIndex, 0)
        compare(board.topStatusText(), "Viewing starting position")
        var king = findChild(board, "boardSquare-e8")
        verify(!king.isCheckSquare)
        tryVerify(function() { return board.flashSquares.length === 0 })
        snapshot.initial_in_check = true
        endpoint.reply(snapshot)
        compare(board.fen, base)
        verify(king.isCheckSquare && king.flashRefresh)

        var from = findChild(board, "boardSquare-b8")
        var to = findChild(board, "boardSquare-c6")
        var origin = from.mapToItem(board, from.width / 2, from.height / 2)
        var target = to.mapToItem(board, to.width / 2, to.height / 2)
        mouseDrag(board, origin.x, origin.y, target.x - origin.x, target.y - origin.y)
        compare(board.selectedSquare, "")
        compare(board.fen, base)

        mouseClick(open, open.width / 2, open.height / 2)
        verify(waitForRendering(loader.item))
        verify(findChild(loader.item, "historyStartingPositionButton").highlighted)
        var goLive = findChild(loader.item, "historyReturnToLiveButton")
        mouseClick(goLive, goLive.width / 2, goLive.height / 2)
        tryCompare(loader, "item", null)
        compare(board.fen, live)
        compare(board.historyIndex, 2)
        verify(!king.isCheckSquare && king.flashRefresh)
        compare(endpoint.sentMessages.length, requests)
    }

    function test_liveHistoryClearUsesTheVisiblePiecesAndMoveMarks_data() {
        return [
            {tag: "marks on", showMarks: true, expected: ["b8", "c6", "f3", "g1"]},
            {tag: "marks off", showMarks: false, expected: ["b8", "c6"]}
        ]
    }

    function test_liveHistoryCaptureTraysFollowAppendsAndTakebacks() {
        var fens = [
            "rnbqkbnr/ppppp1pp/5p2/7Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2",
            "rnbqkbnr/ppppp2p/5pp1/7Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 0 3",
            "rnbqkbnr/ppppp2p/5pQ1/8/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 0 3",
            "rnbqkbnr/ppppp3/5pp1/8/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 0 4"
        ]
        app.openGame("capture-history")
        var snapshot = boardState("capture-history")
        snapshot.fen = fens[1]
        snapshot.position_history = fens.slice(0, 2)
        snapshot.move_history = ["g6"]
        snapshot.capture_history = []
        endpoint.reply(snapshot)

        var append = boardState("capture-history")
        append.position_history = null
        append.move_history = null
        append.fen = fens[2]
        append.turn = "black"
        append.in_check = true
        append.appended_move = "Qxg6+"
        append.appended_capture = "bP"
        append.captured_by_white = ["bP"]
        endpoint.reply(append)
        endpoint.reply(Object.assign({}, append, {
            fen: fens[3], turn: "white", in_check: false, appended_move: "hxg6",
            appended_capture: "wQ", captured_by_black: ["wQ"]
        }))
        var board = screen.item
        var top = findChild(board, "topPlayerBar")
        var bottom = findChild(board, "bottomPlayerBar")
        compare(bottom.capturedPieces, ["bP"])
        compare(top.capturedPieces, ["wQ"])
        board.showHistoryPosition(2)
        compare(bottom.capturedPieces, ["bP"])
        compare(top.capturedPieces, [])
        board.manualFlip = true
        compare(top.capturedPieces, ["bP"])
        compare(bottom.capturedPieces, [])
        endpoint.reply({type: "SettingsState", show_captured_pieces: false})
        compare(top.capturedPieces, [])
        endpoint.reply({type: "SettingsState", show_captured_pieces: true})
        compare(top.capturedPieces, ["bP"])

        board.showHistoryPosition(0)
        compare(top.capturedPieces, [])
        compare(bottom.capturedPieces, [])
        board.returnToLive()
        compare(top.capturedPieces, ["bP"])
        compare(bottom.capturedPieces, ["wQ"])
        snapshot.fen = fens[2]
        snapshot.turn = "black"
        snapshot.position_history = fens.slice(0, 3)
        snapshot.move_history = ["g6", "Qxg6+"]
        snapshot.capture_history = [{ply: 2, piece: "bP"}]
        snapshot.captured_by_white = ["bP"]
        endpoint.reply(snapshot)
        compare(board.historyIndex, 2)
        compare(top.capturedPieces, ["bP"])
        compare(bottom.capturedPieces, [])
        board.showHistoryPosition(1)
        compare(top.capturedPieces, [])
    }

    function test_legacyHistoryLeavesUndatedCaptureTraysEmpty() {
        app.openGame("legacy-captures")
        var snapshot = boardState("legacy-captures")
        snapshot.fen = "rnbqkbnr/ppp1pppp/8/3P4/8/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2"
        snapshot.turn = "black"
        snapshot.position_history = [
            "rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
            snapshot.fen
        ]
        snapshot.move_history = ["exd5"]
        snapshot.captured_by_white = ["bP"]
        endpoint.reply(snapshot)
        var board = screen.item
        var bottom = findChild(board, "bottomPlayerBar")
        compare(bottom.capturedPieces, ["bP"])
        board.showHistoryPosition(0)
        compare(bottom.capturedPieces, [])
        board.returnToLive()
        compare(bottom.capturedPieces, ["bP"])
    }

    function test_liveHistoryClearUsesTheVisiblePiecesAndMoveMarks(data) {
        var fens = [
            startFen,
            "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2",
            "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3"
        ]
        endpoint.reply({type: "SettingsState", highlight_last_move: data.showMarks})
        app.openGame("live-history-clear")
        var snapshot = boardState("live-history-clear")
        snapshot.fen = fens[4]
        snapshot.position_history = fens
        snapshot.move_history = ["e4", "e5", "Nf3", "Nc6"]
        snapshot.last_move = ["b8", "c6"]
        endpoint.reply(snapshot)
        var board = screen.item
        compare(board.flashSquares, [])

        board.showHistoryPosition(3)
        compare(board.flashSquares.slice().sort(), data.expected)
        var previousMark = findChild(board, "boardSquare-g1")
        compare(previousMark.isLastMove, data.showMarks)
        compare(previousMark.flashRefresh, data.showMarks)
        board.returnToLive()
        compare(board.flashSquares.slice().sort(), data.expected)
        tryVerify(function() { return board.flashSquares.length === 0 })
        board.returnToLive()
        compare(board.flashSquares, [])

        board.showHistoryPosition(3)
        board.showHistoryPosition(2)
        compare(board.flashSquares.slice().sort(), data.showMarks
                ? ["b8", "c6", "e5", "e7", "f3", "g1"] : ["b8", "c6", "f3", "g1"])
        board.showHistoryPosition(1)
        tryVerify(function() { return board.flashSquares.length === 0 })
        var liveFen = "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3"
        var advance = boardState("live-history-clear")
        advance.fen = liveFen
        advance.turn = "black"
        advance.position_history = null
        advance.move_history = null
        advance.appended_move = "Bc4"
        advance.last_move = ["f1", "c4"]
        endpoint.reply(advance)
        compare(board.fen, liveFen)
        compare(board.historyIndex, 5)
        compare(board.flashSquares.slice().sort(), data.showMarks
                ? ["b8", "c4", "c6", "e2", "e4", "e5", "e7", "f1", "f3", "g1"]
                : ["b8", "c4", "c6", "e5", "e7", "f1", "f3", "g1"])
    }

    function test_liveHistoryClearsCheckMarksWithoutMovingAPiece() {
        var sameBoard = "4k3/8/8/8/8/8/4r3/4K3 w - - 1 2"
        app.openGame("live-history-check")
        var snapshot = boardState("live-history-check")
        snapshot.fen = sameBoard
        snapshot.position_history = [sameBoard, sameBoard]
        snapshot.move_history = ["Re2+"]
        snapshot.in_check = true
        endpoint.reply(snapshot)
        var board = screen.item
        var king = findChild(board, "boardSquare-e1")
        verify(king.isCheckSquare)
        board.showHistoryPosition(0)
        verify(!king.isCheckSquare && king.flashRefresh)
        compare(board.flashSquares, ["e1"])
        tryVerify(function() { return board.flashSquares.length === 0 })
        board.returnToLive()
        verify(king.isCheckSquare && king.flashRefresh)
        compare(board.flashSquares, ["e1"])
    }

    function test_historicalCheckUsesTheSideToMove_data() {
        return [{tag: "archive", live: false}, {tag: "live Move history", live: true}]
    }

    function test_historicalCheckUsesTheSideToMove(data) {
        var before = "rnbqkbnr/ppppp1pp/5p2/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var checked = "rnbqkbnr/ppppp1pp/5p2/7Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2"
        var after = "rnbqkbnr/ppppp2p/5pp1/7Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 0 3"
        var fens = [before, checked, after]
        var moves = ["Qh5+", "g6"]
        endpoint.reply({type: "SettingsState", highlight_last_move: false})
        if (data.live) {
            app.openGame("historical-check")
            var snapshot = boardState("historical-check")
            snapshot.fen = after
            snapshot.position_history = fens
            snapshot.move_history = moves
            endpoint.reply(snapshot)
        } else {
            var requestId = choose("historical-check")
            endpoint.reply({type: "GameMoves", request_id: requestId, moves: moves, fens: fens,
                            analysis: [{judgment: "Inaccuracy"}]})
        }
        var board = screen.item
        board.manualFlip = true
        var whiteKing = findChild(board, "boardSquare-e1")
        var blackKing = findChild(board, "boardSquare-e8")
        verify(!whiteKing.isCheckSquare && !blackKing.isCheckSquare)
        if (data.live) board.showHistoryPosition(1)
        else board.goNext()
        verify(blackKing.isCheckSquare && blackKing.flashRefresh)
        verify(!whiteKing.isCheckSquare)
        tryVerify(function() { return board.flashSquares.length === 0 })

        if (data.live) {
            board.returnToLive()
            verify(!blackKing.isCheckSquare && blackKing.flashRefresh)
            return
        }

        board.beginExploration()
        verify(blackKing.isCheckSquare && !blackKing.flashRefresh)
        endpoint.reply({type: "AnalysisPosition", request_id: board.pendingAnalysisRequestId,
                        requested_fen: checked, fen: checked, in_check: true, status: "check",
                        legal_moves: [{from: "g7", to: "g6"}]})
        verify(blackKing.isCheckSquare && !blackKing.flashRefresh)
        verify(board.requestExplorationMove("g7", "g6"))
        endpoint.reply({type: "AnalysisMove", request_id: board.pendingAnalysisRequestId,
                        from_fen: checked, fen: after, san: "g6", in_check: false})
        verify(!blackKing.isCheckSquare && blackKing.flashRefresh)
        tryVerify(function() { return board.flashSquares.length === 0 })

        board.undoExplorationMove()
        verify(blackKing.isCheckSquare && blackKing.flashRefresh)
        board.stopExploration()
        verify(blackKing.isCheckSquare)
        tryVerify(function() { return board.flashSquares.length === 0 })
        board.goNext()
        verify(!blackKing.isCheckSquare && blackKing.flashRefresh)
    }

    function test_archiveCheckmateMarksTheKingInCheck() {
        var before = "rnbqkbnr/pppp1ppp/8/4p3/6P1/5P2/PPPPP2P/RNBQKBNR b KQkq - 0 2"
        var after = "rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3"
        var requestId = choose("archive-mate")
        endpoint.reply({type: "GameMoves", request_id: requestId, moves: ["Qh4#"], fens: [before, after]})
        var review = screen.item
        var whiteKing = findChild(review, "boardSquare-e1")
        verify(!whiteKing.isCheckSquare)
        review.goNext()
        verify(whiteKing.isCheckSquare && whiteKing.flashRefresh)
        verify(!findChild(review, "boardSquare-e8").isCheckSquare)
    }

    function test_customArchiveStartsInCheckAndKeepsItScopedToThePosition() {
        var checked = "rnbqkbnr/ppppp1pp/5p2/7Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2"
        var after = "rnbqkbnr/ppppp2p/5pp1/7Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 0 3"
        var requestId = choose("checked-custom-start")
        var reply = {type: "GameMoves", request_id: requestId, moves: ["g6"],
                     fens: [checked, after], initial_in_check: true}
        endpoint.reply(reply)
        var review = screen.item
        var king = findChild(review, "boardSquare-e8")
        compare(review.currentIndex, 0)
        verify(king.isCheckSquare && !king.flashRefresh)
        review.goNext()
        verify(!king.isCheckSquare && king.flashRefresh)
        tryVerify(function() { return review.flashSquares.length === 0 })
        review.goFirst()
        verify(king.isCheckSquare && king.flashRefresh)
        tryVerify(function() { return review.flashSquares.length === 0 })

        review.beginExploration()
        verify(king.isCheckSquare && !king.flashRefresh)
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: checked, fen: checked, in_check: true, status: "check",
                        legal_moves: [{from: "g7", to: "g6"}]})
        verify(king.isCheckSquare && !king.flashRefresh)
        verify(review.requestExplorationMove("g7", "g6"))
        endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                        from_fen: checked, fen: after, san: "g6", in_check: false})
        verify(!king.isCheckSquare && king.flashRefresh)
        review.undoExplorationMove()
        verify(king.isCheckSquare)
        review.stopExploration()
        verify(king.isCheckSquare)

        review.returnToGameHistory()
        var oldBackend = choose("older-review-payload")
        endpoint.reply(reply)
        verify(String(screen.source).endsWith("GameHistoryScreen.qml"))
        endpoint.reply({type: "GameMoves", request_id: oldBackend, moves: [], fens: [startFen]})
        compare(screen.item.currentFen(), startFen)
        verify(!findChild(screen.item, "boardSquare-e8").isCheckSquare)
    }

    function test_livePreviewConfirmationOnlyClearsAChangedBoard() {
        app.openGame("preview-refresh")
        var snapshot = boardState("preview-refresh")
        snapshot.legal_moves = [{from: "e2", to: "e4"}]
        endpoint.reply(snapshot)
        var board = screen.item
        board.requestMove("e2", "e4", null)
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "MakeMove")
        var after = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        endpoint.reply({type: "MovePreview", game_id: "preview-refresh", request_id: request.request_id,
                        fen: after, turn: "black", last_move: ["e2", "e4"],
                        white_time_ms: 100000, black_time_ms: 100000})
        compare(board.fen, after)
        compare(board.flashSquares.slice().sort(), ["e2", "e4"])
        tryVerify(function() { return board.flashSquares.length === 0 })

        snapshot.fen = after
        snapshot.turn = "black"
        snapshot.position_history = [startFen, after]
        snapshot.move_history = ["e4"]
        snapshot.last_move = ["e2", "e4"]
        snapshot.resolved_move_request_id = request.request_id
        endpoint.reply(snapshot)
        compare(board.fen, after)
        compare(board.previewFen, "")
        compare(board.flashSquares, [])
    }

    function test_liveCapturePreviewUsesOnlyTheDisplayedPosition_data() {
        return [{tag: "confirmation", action: "confirm"},
                {tag: "rejection", action: "reject"},
                {tag: "history", action: "history"},
                {tag: "game switch", action: "switch"}]
    }

    function test_liveCapturePreviewUsesOnlyTheDisplayedPosition(data) {
        var before = "rnbqkbnr/ppppp1pp/5p2/7Q/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 1 2"
        var live = "rnbqkbnr/ppppp2p/5pp1/7Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 0 3"
        var after = "rnbqkbnr/ppppp2p/5pQ1/8/4P3/8/PPPP1PPP/RNB1KBNR b KQkq - 0 3"
        var snapshot = boardState("capture-preview")
        snapshot.fen = live
        snapshot.position_history = [before, live]
        snapshot.move_history = ["g6"]
        snapshot.capture_history = []
        snapshot.legal_moves = [{from: "h5", to: "g6"}]
        app.openGame(snapshot.game_id)
        endpoint.reply(snapshot)
        var board = screen.item
        board.manualFlip = (data.action === "confirm")
        var white = findChild(board, board.manualFlip ? "topPlayerBar" : "bottomPlayerBar")
        var black = findChild(board, board.manualFlip ? "bottomPlayerBar" : "topPlayerBar")
        board.requestMove("h5", "g6", null)
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "MakeMove")
        var preview = {type: "MovePreview", game_id: snapshot.game_id, request_id: request.request_id,
                       fen: after, turn: "black", last_move: ["h5", "g6"], in_check: true,
                       white_time_ms: 590000, black_time_ms: 600000, captured_piece: "bP"}
        var reject = {type: "MoveRejected", game_id: snapshot.game_id, request_id: request.request_id,
                      reason: "Capture refused"}
        endpoint.reply(preview)
        compare(white.capturedPieces, ["bP"])
        compare(black.capturedPieces, [])
        compare(white.materialText, "+1")
        compare(board.capturedByWhite, [])
        tryVerify(function() { return board.flashSquares.length === 0 })

        endpoint.reply(Object.assign({}, reject, {request_id: request.request_id + 1}))
        endpoint.reply({type: "GameStreamReconnecting", game_id: snapshot.game_id})
        endpoint.reply(Object.assign({}, snapshot, {game_stream_connected: true, white_time_ms: 591000}))
        compare(board.fen, after)
        compare(white.capturedPieces, ["bP"])

        if (data.action === "confirm") {
            endpoint.reply(Object.assign({}, snapshot, {
                fen: after, turn: "black", last_move: ["h5", "g6"], in_check: true,
                position_history: null, move_history: null, capture_history: null,
                appended_move: "Qxg6+", appended_capture: "bP", captured_by_white: ["bP"],
                resolved_move_request_id: request.request_id
            }))
            endpoint.reply(reject)
            compare(board.fen, after)
            compare(board.flashSquares, [])
            compare(white.capturedPieces, ["bP"])
            compare(board.capturedByWhite, ["bP"])
        } else if (data.action === "history") {
            board.showHistoryPosition(0)
            endpoint.reply(preview)
            endpoint.reply(reject)
            compare(board.fen, before)
            compare(white.capturedPieces, [])
            board.returnToLive()
            compare(board.fen, live)
            compare(white.capturedPieces, [])
        } else if (data.action === "switch") {
            app.openGame("next-game")
            endpoint.reply(boardState("next-game"))
            endpoint.reply(preview)
            endpoint.reply(reject)
            compare(screen.item.fen, startFen)
            compare(findChild(screen.item, "bottomPlayerBar").capturedPieces, [])
        } else {
            app.setShowCapturedPieces(false)
            compare(white.capturedPieces, [])
            app.setShowCapturedPieces(true)
            compare(white.capturedPieces, ["bP"])
            endpoint.reply(reject)
            compare(board.fen, live)
            compare(white.capturedPieces, [])
            compare(white.materialText, "")
        }
    }

    function test_liveHistoryClearsThePreviewWithoutReintroducingItOnRejection() {
        var afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        var afterE5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var afterNf3 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"
        app.openGame("preview-history")
        var snapshot = boardState("preview-history")
        snapshot.fen = afterE5
        snapshot.position_history = [startFen, afterE4, afterE5]
        snapshot.move_history = ["e4", "e5"]
        snapshot.last_move = ["e7", "e5"]
        snapshot.legal_moves = [{from: "g1", to: "f3"}]
        endpoint.reply(snapshot)
        var board = screen.item
        board.requestMove("g1", "f3", null)
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "MakeMove")
        endpoint.reply({type: "MovePreview", game_id: "preview-history", request_id: request.request_id,
                        fen: afterNf3, turn: "black", last_move: ["g1", "f3"],
                        white_time_ms: 100000, black_time_ms: 100000})
        compare(board.fen, afterNf3)
        tryVerify(function() { return board.flashSquares.length === 0 })

        board.showHistoryPosition(1)
        compare(board.fen, afterE4)
        compare(board.previewFen, "")
        compare(board.flashSquares.slice().sort(), ["e2", "e4", "e5", "e7", "f3", "g1"])
        tryVerify(function() { return board.flashSquares.length === 0 })
        endpoint.reply({type: "MoveRejected", game_id: "preview-history",
                        request_id: request.request_id, reason: "stale move"})
        compare(board.fen, afterE4)
        compare(board.flashSquares, [])
    }

    function test_archiveReplayPagesWholeMoveRows_data() {
        return [
            {tag: "Paper Pro Move timed", width: 954, height: 1696, timedPlies: 24},
            {tag: "Paper Pro timed", width: 1620, height: 2160, timedPlies: 24},
            {tag: "Paper Pro Move mixed", width: 954, height: 1696, timedPlies: 9},
            {tag: "Paper Pro Move untimed", width: 954, height: 1696, timedPlies: 0}
        ]
    }

    function test_archiveReplayPagesWholeMoveRows(data) {
        width = data.width
        height = data.height
        var requestId = choose("score-sheet")
        var moves = []
        var fens = [startFen]
        var clocks = []
        for (var i = 0; i < 24; i++) {
            moves.push(["Nf3", "Nf6", "Ng1", "Ng8"][i % 4])
            fens.push(startFen)
            if (i < data.timedPlies) clocks.push(600000 - i * 1000)
        }
        endpoint.reply({type: "GameMoves", request_id: requestId, moves: moves, fens: fens, clock_ms: clocks})
        var review = screen.item
        verify(waitForRendering(review))
        var pager = findChild(review, "reviewMoveList")
        var rows = []
        function collectRows(item) {
            if (item.objectName === "archiveMoveRow") rows.push(item)
            for (var i = 0; i < item.children.length; i++) collectRows(item.children[i])
        }
        collectRows(pager)
        compare(rows.length, 12)
        function rowFits(row) {
            var y = row.mapToItem(pager, 0, 0).y
            return y >= -0.5 && y + row.height <= pager.pageHeight + 0.5
        }
        var next = findChild(pager, "pageDownButton")
        var previous = findChild(pager, "pageUpButton")
        var seenRows = {}
        verify(pager.pageCount > 1)
        for (var page = 1; page <= pager.pageCount; page++) {
            compare(pager.currentPage, page)
            for (var row = 0; row < rows.length; row++) {
                if (!rowFits(rows[row])) continue
                compare(rows[row].hasClock, row * 2 < data.timedPlies)
                seenRows[row] = true
            }
            if (page < pager.pageCount) mouseClick(next, next.width / 2, next.height / 2)
        }
        compare(Object.keys(seenRows).length, rows.length)
        for (page = pager.pageCount - 1; page > 0; page--) {
            mouseClick(previous, previous.width / 2, previous.height / 2)
            compare(pager.currentPage, page)
        }

        review.goLast()
        tryVerify(function() { return rowFits(rows[11]) })
        verify(findChild(rows[11], "blackMoveCell").isCurrent)
        var white = findChild(rows[11], "whiteMoveCell")
        mouseClick(white, white.width / 2, white.height / 2)
        compare(review.currentIndex, 23)
        verify(white.isCurrent)
        review.goFirst()
        tryCompare(pager, "contentY", 0)
    }

    function test_denseArchiveReplayKeepsATimedRowAndBothControlsUsable() {
        screen.item.selectGameForReview({game_id: "dense-sheet", opponent_name: "Opponent",
                                        opponent_rating: 1660, rating_diff: 6,
                                        result: "win", speed: "rapid", rated: true, termination: "mate",
                                        opening_name: "Italian Game: Giuoco Pianissimo, Italian Four Knights Variation",
                                        created_at_ms: 1795500619000, your_color: "white",
                                        your_analysis: {accuracy: 92, inaccuracies: 1, mistakes: 1, blunders: 0}})
        var requestId = endpoint.sentMessages[endpoint.sentMessages.length - 1].request_id
        var moves = ["Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6"]
        endpoint.reply({type: "GameMoves", request_id: requestId, moves: moves,
                        fens: [startFen, startFen, startFen, startFen, startFen, startFen, startFen],
                        clock_ms: [600000, 600000, 590000, 590000, 580000, 580000],
                        analysis: [{eval_cp: 12, judgment: "Inaccuracy", judgment_comment: "Inaccuracy. d4 was best."}]})
        var review = screen.item
        review.goNext()
        review.requestCloudEvaluation()
        var cloud = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        endpoint.reply({type: "CloudEvaluation", request_id: cloud.request_id, requested_fen: cloud.fen,
                        evaluation: {depth: 29, knodes: 22000, eval_cp: 12, best_line: ["e4"]}})
        verify(waitForRendering(review))
        var pager = findChild(review, "reviewMoveList")
        var row = findChild(pager, "archiveMoveRow")
        verify(row.hasClock)
        verify(pager.pageHeight >= row.height)
        verify(findChild(review, "cloudBestLineButton").visible)
        verify(findChild(review, "reviewMoveJudgment").visible)
        var next = findChild(pager, "pageDownButton")
        var previous = findChild(pager, "pageUpButton")
        mouseClick(next, next.width / 2, next.height / 2)
        compare(pager.currentPage, 2)
        mouseClick(previous, previous.width / 2, previous.height / 2)
        compare(pager.currentPage, 1)
        compare(review.currentIndex, 1)
    }

    function test_exploreStatusReportsFailuresAndCheckmateAlongsideTheCandidate() {
        var base = "7k/5Q2/6K1/8/8/8/8/8 w - - 0 1"
        var afterMate = "7k/6Q1/6K1/8/8/8/8/8 b - - 1 1"
        var requestId = choose("candidate-status")
        endpoint.reply({type: "GameMoves", request_id: requestId, fens: [base], moves: []})
        var review = screen.item
        var status = findChild(review, "reviewPositionStatus")
        review.beginExploration()
        compare(status.text, "Loading legal moves...")
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: base, fen: base, legal_moves: [{from: "f7", to: "g7"}]})
        verify(review.requestExplorationMove("f7", "g7"))
        compare(status.text, "Applying move...")

        var firstAttempt = review.pendingAnalysisRequestId
        endpoint.reply({type: "AnalysisFailed", request_id: firstAttempt, message: "Retry this move"})
        compare(status.text, "Retry this move")
        verify(review.requestExplorationMove("f7", "g7"))
        endpoint.reply({type: "AnalysisFailed", request_id: firstAttempt, message: "stale error"})
        compare(status.text, "Applying move...")
        endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                        from_fen: base, fen: afterMate, san: "Qg7#", legal_moves: [],
                        status: "checkmate", in_check: true})
        compare(status.text, "Checkmate — candidate line ends.")
        compare(review.currentFen(), afterMate)
        var row = findChild(review, "candidateMoveRow")
        compare(row.whiteMove.san, "Qg7#")
        review.undoExplorationMove()
        compare(status.text, "Loading legal moves...")
        compare(review.variationMoves, [])
        compare(review.currentFen(), base)
    }

    function test_exploreJudgmentFollowsTheArchivedMove() {
        var afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        var archiveE4 = afterE4.replace(" - ", " e3 ")
        var afterE5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var e4Comment = "Inaccuracy. d4 was best."
        var e5Comment = "Mistake. c5 was best."
        var requestId = choose("archive-judgments")
        endpoint.reply({type: "GameMoves", request_id: requestId,
                        fens: [startFen, archiveE4, afterE5], moves: ["e4", "e5"],
                        analysis: [
                            {eval_cp: 0, judgment: "Inaccuracy", judgment_comment: e4Comment},
                            {eval_cp: 50, judgment: "Mistake", judgment_comment: e5Comment}
                        ]})
        var review = screen.item
        var judgment = findChild(review, "reviewMoveJudgment")
        verify(!judgment.visible)
        review.goNext()
        verify(judgment.visible)
        compare(judgment.text, e4Comment)

        function loadBase(requestedFen) {
            endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                            requested_fen: requestedFen, fen: afterE4,
                            legal_moves: [{from: "e7", to: "e5"}]})
            compare(review.currentFen(), afterE4)
            verify(judgment.visible)
            compare(judgment.text, e4Comment)
        }

        function playE5() {
            verify(review.requestExplorationMove("e7", "e5"))
            verify(judgment.visible)
            endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                            from_fen: afterE4, fen: afterE5, san: "e5"})
            compare(review.currentFen(), afterE5)
            compare(review.variationMoves, ["e5"])
            verify(!judgment.visible)
        }

        review.beginExploration()
        loadBase(archiveE4)
        playE5()
        review.requestCloudEvaluation()
        var cloud = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(cloud.fen, afterE5)
        endpoint.reply({type: "CloudEvaluation", request_id: cloud.request_id, requested_fen: cloud.fen,
                        evaluation: {depth: 24, knodes: 50, eval_cp: 10, best_line: ["Nf3"]}})
        compare(review.cloudBestMoves, ["Nf3"])
        verify(!judgment.visible)

        review.undoExplorationMove()
        loadBase(afterE4)
        compare(review.cloudBestMoves, [])
        playE5()
        review.rebaseExploration()
        loadBase(archiveE4)
        playE5()
        review.stopExploration()
        compare(review.currentFen(), archiveE4)
        verify(judgment.visible)
        compare(judgment.text, e4Comment)

        review.beginExploration()
        loadBase(archiveE4)
        playE5()
        var archiveRow = findChild(review, "archiveMoveRow")
        compare(archiveRow.whiteMove.judgment, "Inaccuracy")
        compare(archiveRow.blackMove.judgment, "Mistake")
        var archivedMove = findChild(archiveRow, "blackMoveCell")
        mouseClick(archivedMove, archivedMove.width / 2, archivedMove.height / 2)
        compare(review.currentIndex, 2)
        compare(review.variationMoves, [])
        verify(judgment.visible)
        compare(judgment.text, e5Comment)
        compare(review.cloudBestMoves, ["Nf3"])
    }

    function test_exploreRefreshCoversFootprintAndOverlappingPulses_data() {
        return [
            {tag: "new move before the first pulse ends", highlights: false, settleFirst: false,
             squares: ["e2", "e4", "e5", "e7"]},
            {tag: "old last-move marks still need clearing", highlights: true, settleFirst: true,
             squares: ["e2", "e4", "e5", "e7"]},
            {tag: "hidden last-move marks do not expand the pulse", highlights: false, settleFirst: true,
             squares: ["e5", "e7"]}
        ]
    }

    function test_exploreRefreshCoversFootprintAndOverlappingPulses(data) {
        var afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        var afterE5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        endpoint.reply({type: "SettingsState", highlight_last_move: data.highlights})
        var requestId = choose("explore-refresh")
        endpoint.reply({type: "GameMoves", request_id: requestId,
                        fens: [startFen, afterE4], moves: ["e4"]})
        var review = screen.item
        review.beginExploration()
        compare(review.flashSquares, [])
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: startFen, fen: startFen, legal_moves: [{from: "e2", to: "e4"}]})
        verify(review.requestExplorationMove("e2", "e4"))
        endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                        from_fen: startFen, fen: afterE4, san: "e4", legal_moves: [{from: "e7", to: "e5"}]})
        compare(review.flashSquares.slice().sort(), ["e2", "e4"])
        if (data.settleFirst) tryVerify(function() { return review.flashSquares.length === 0 })

        verify(review.requestExplorationMove("e7", "e5"))
        endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                        from_fen: afterE4, fen: afterE5, san: "e5", legal_moves: []})
        compare(review.flashSquares.slice().sort(), data.squares)
        var e5 = findChild(review, "boardSquare-e5")
        verify(findChild(e5, "refreshFlash").visible && e5.fastRefresh)
        tryVerify(function() { return review.flashSquares.length === 0 })

        review.goNext()
        compare(review.currentFen(), afterE4)
        compare(review.variationMoves, [])
        compare(review.flashSquares.slice().sort(), data.highlights ? ["e2", "e4", "e5", "e7"] : ["e5", "e7"])
    }

    function test_specialMoveReplayHighlightsEndpointsAndRefreshesEveryChangedPiece() {
        var beforeCastle = "4k3/8/8/8/8/8/8/4K2R w K - 0 1"
        var afterCastle = "4k3/8/8/8/8/8/8/5RK1 b - - 1 1"
        var afterReply = "8/3k4/8/8/8/8/8/5RK1 w - - 2 2"
        app.openGame("castle-history")
        var snapshot = boardState("castle-history")
        snapshot.fen = afterReply
        snapshot.position_history = [beforeCastle, afterCastle, afterReply]
        snapshot.move_history = ["O-O", "Kd7"]
        snapshot.last_move = ["e8", "d7"]
        endpoint.reply(snapshot)
        var board = screen.item
        board.showHistoryPosition(0)
        tryVerify(function() { return board.flashSquares.length === 0 })
        board.showHistoryPosition(1)
        compare(board.flashSquares.slice().sort(), ["e1", "f1", "g1", "h1"])
        verify(findChild(board, "boardSquare-e1").isLastMove)
        verify(findChild(board, "boardSquare-g1").isLastMove)
        verify(!findChild(board, "boardSquare-f1").isLastMove)
        verify(!findChild(board, "boardSquare-h1").isLastMove)

        var beforeCapture = "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 4"
        var afterCapture = "4k3/8/3P4/8/8/8/8/4K3 b - - 0 4"
        app.navigateTo("GameHistoryScreen.qml")
        var requestId = choose("en-passant-history")
        endpoint.reply({type: "GameMoves", request_id: requestId,
                        fens: [beforeCapture, afterCapture], moves: ["exd6"]})
        var review = screen.item
        review.goNext()
        compare(review.flashSquares.slice().sort(), ["d5", "d6", "e5"])
        verify(findChild(review, "boardSquare-e5").isLastMove)
        verify(findChild(review, "boardSquare-d6").isLastMove)
        verify(!findChild(review, "boardSquare-d5").isLastMove)
    }

    function test_exploreRefreshTracksTheCheckedKingWithoutPieceChanges() {
        var fen = "4k3/8/8/8/8/8/4r3/4K3 w - - 0 1"
        var requestId = choose("check-refresh")
        endpoint.reply({type: "GameMoves", request_id: requestId, fens: [fen], moves: []})
        var review = screen.item
        var king = findChild(review, "boardSquare-e1")
        review.beginExploration()
        compare(review.flashSquares, [])
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: fen, fen: fen, legal_moves: [{from: "e1", to: "e2"}],
                        status: "check", in_check: true})
        compare(review.currentFen(), fen)
        verify(king.isCheckSquare && king.flashRefresh)
        compare(review.flashSquares, ["e1"])
        tryVerify(function() { return review.flashSquares.length === 0 })
        verify(king.isCheckSquare && !king.fastRefresh)

        review.stopExploration()
        compare(review.currentFen(), fen)
        verify(!king.isCheckSquare && king.flashRefresh)
        compare(review.flashSquares, ["e1"])
    }

    function test_exploreRefreshIgnoresNormalizationAndUnappliedMoves() {
        var archiveFen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"
        var normalized = archiveFen.replace(" e3 ", " - ")
        var afterE5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var requestId = choose("normalize-refresh")
        endpoint.reply({type: "GameMoves", request_id: requestId, fens: [archiveFen], moves: []})
        var review = screen.item
        review.beginExploration()
        var initial = review.pendingAnalysisRequestId
        endpoint.reply({type: "AnalysisPosition", request_id: initial,
                        requested_fen: archiveFen, fen: normalized, legal_moves: [{from: "e7", to: "e5"}]})
        compare(review.currentFen(), normalized)
        compare(review.flashSquares, [])

        verify(review.requestExplorationMove("e7", "e5"))
        endpoint.reply({type: "AnalysisMove", request_id: initial,
                        from_fen: normalized, fen: afterE5, san: "e5", legal_moves: []})
        compare(review.currentFen(), normalized)
        compare(review.flashSquares, [])
        endpoint.reply({type: "AnalysisFailed", request_id: review.pendingAnalysisRequestId,
                        message: "Move rejected"})
        compare(review.currentFen(), normalized)
        compare(review.flashSquares, [])
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

    function pgnRequests() {
        return endpoint.sentMessages.filter(function(message) { return message.type === "RequestPgnExport" })
    }

    function test_reviewPgnExportTracksRetryReceiptAndCancellation() {
        app.openGameReview("arch0001", null)
        var request = endpoint.sentMessages.slice(-1)[0]
        replyWithMoves(request.request_id, "e4")
        var review = screen.item
        review.goNext()
        review.showReviewOptions = true
        var action = findChild(review, "openPgnExportButton")
        verify(action && waitForRendering(action))
        compare(pgnRequests().length, 0)
        mouseClick(action, action.width / 2, action.height / 2)
        var dialog = findChild(app, "pgnExportDialog")
        var status = findChild(dialog, "pgnExportStatus")
        var file = findChild(dialog, "pgnExportPath")
        verify(dialog.visible && dialog.saving)
        compare(status.text, "Saving PGN…")
        var first = pgnRequests().slice(-1)[0]
        compare(first.game_id, "arch0001")
        endpoint.reply({type: "PgnExported", request_id: first.request_id, game_id: "wrong001", path: "/wrong"})
        verify(dialog.saving && !file.visible)

        endpoint.reply({type: "PgnExportFailed", request_id: first.request_id, game_id: "arch0001",
                        retry_after_ms: 400, message: "Lichess limited PGN export requests."})
        var retry = findChild(dialog, "savePgnButton")
        verify(retry.visible && !retry.enabled)
        compare(retry.text, "Retry available shortly")
        dialog.requestSave()
        compare(pgnRequests().length, 1)
        tryCompare(retry, "enabled", true)
        compare(pgnRequests().length, 1)
        retry.clicked()
        var retried = pgnRequests().slice(-1)[0]
        verify(retried.request_id > first.request_id)
        var path = "/home/root/.config/remarkable-lichess/exports/arch0001.pgn"
        endpoint.reply({type: "PgnExported", request_id: retried.request_id, game_id: "arch0001", path: path})
        compare(status.text, "PGN saved")
        compare(file.text, path)
        verify(file.visible)
        compare(review.currentIndex, 1)

        compare(retry.text, "Export again")
        retry.clicked()
        var canceled = pgnRequests().slice(-1)[0]
        var close = findChild(dialog, "closePgnExportButton")
        compare(close.text, "Cancel")
        close.clicked()
        compare(endpoint.sentMessages.slice(-1)[0],
                {type: "CancelPgnExport", request_id: canceled.request_id})
        endpoint.reply({type: "PgnExported", request_id: canceled.request_id,
                        game_id: "arch0001", path: "/unexpected"})
        verify(!dialog.visible && !dialog.saving)
        compare(file.text, path)
        compare(pgnRequests().length, 3)
        compare(screen.item, review)
    }

    function test_historyCanExportAVariantWithoutOpeningReview() {
        var history = screen.item
        endpoint.reply({type: "GameHistory", request_id: history.pendingHistoryRequest,
                        games: [{game_id: "var00001", variant: "crazyhouse", review_supported: false}]})
        var card = findChild(history, "historyGameRow")
        verify(card && waitForRendering(card))
        compare(findChild(card, "historyReviewUnavailable").text, "Review unavailable · Export PGN")
        var before = endpoint.sentMessages.length
        mouseClick(card, card.width / 2, card.height / 2)
        var dialog = findChild(app, "pgnExportDialog")
        verify(dialog.visible && !dialog.saving)
        compare(dialog.gameId, "var00001")
        compare(endpoint.sentMessages.length, before)
        findChild(dialog, "savePgnButton").clicked()
        var saved = pgnRequests().slice(-1)[0]
        compare(saved.game_id, "var00001")
        verify(dialog.saving)
        compare(screen.item, history)

        endpoint.reply({type: "AuthenticationRequired"})
        verify(!dialog.visible && !dialog.saving)
        endpoint.reply({type: "PgnExported", request_id: saved.request_id,
                        game_id: "var00001", path: "/unexpected"})
        compare(dialog.savedPath, "")
        verify(String(screen.source).endsWith("LoginScreen.qml"))
    }

    function test_historyRateLimitHoldsInitialRetryAcrossFilterChanges() {
        var requestId = applyHistoryFilters("rapid")
        var history = screen.item
        var retry = findChild(history, "retryGameHistoryButton")
        var message = "Lichess limited game history requests."
        endpoint.reply({type: "GameHistoryFailed", request_id: requestId,
                        message: message, retry_after_ms: 1200})
        var requestCount = historyRequests().length
        compare(applyHistoryFilters("blitz"), 0)
        verify(retry.visible && !retry.enabled)
        compare(retry.text, "Retry available shortly")
        compare(findChild(history, "historyHeader").detail, "")
        verify(waitForRendering(retry))
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(history.filterSummary(), "Rated · Blitz · Played Black")
        compare(history.loadError, message)
        verify(!history.loading && !retry.enabled)
        compare(historyRequests().length, requestCount)

        tryCompare(retry, "enabled", true)
        compare(retry.text, "Retry")
        compare(historyRequests().length, requestCount)
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(historyRequests().length, requestCount + 1)
        var retried = historyRequests().slice(-1)[0]
        compare(retried, {type: "RequestGameHistory", request_id: retried.request_id,
                          rated: true, speed: "blitz", color: "black"})
        endpoint.reply({type: "GameHistory", request_id: retried.request_id,
                        games: [{game_id: "blitz"}]})
        compare(history.loadError, "")
        compare(history.games[0].game_id, "blitz")
        compare(findChild(history, "historyHeader").detail, "1 game loaded")
    }

    function test_historyRateLimitPreservesTheOlderPageThroughReview() {
        var requestId = applyHistoryFilters("rapid")
        var games = []
        for (var index = 0; index < 20; index++) {
            games.push({game_id: "limited-" + index, opponent_name: "Opponent " + index, result: "draw"})
        }
        var cursor = {until_ms: 1765526400001}
        endpoint.reply({type: "GameHistory", request_id: requestId, games: games, next_cursor: cursor})
        var history = screen.item
        var pager = findChild(history, "historyList")
        var older = findChild(history, "loadOlderGamesButton")
        var next = findChild(pager, "pageDownButton")
        verify(waitForRendering(pager))
        for (var page = 1; page < pager.pageCount; page++) next.clicked()
        verify(!next.enabled)
        var offset = pager.contentY
        verify(waitForRendering(older))
        mouseClick(older, older.width / 2, older.height / 2)
        var limited = historyRequests().slice(-1)[0]
        compare(limited.cursor, cursor)
        var requestCount = historyRequests().length
        var message = "Lichess limited game history requests."
        endpoint.reply({type: "GameHistoryFailed", request_id: limited.request_id,
                        message: message, retry_after_ms: 1500})
        verify(!older.enabled)
        compare(older.title, "Retry available shortly")
        compare(older.subtitle, message)
        compare(pager.contentY, offset)
        history.loadOlderGames()
        compare(historyRequests().length, requestCount)
        var deadline = history.historyRetryAt

        var reviewRequest = choose(games[19].game_id)
        replyWithMoves(reviewRequest, "e4")
        findChild(screen.item, "reviewBackButton").clicked()
        var returned = screen.item
        var returnedPager = findChild(returned, "historyList")
        var returnedOlder = findChild(returned, "loadOlderGamesButton")
        compare(returned.historyRetryAt, deadline)
        compare(returned.nextHistoryCursor, cursor)
        compare(returned.games.length, 20)
        compare(returnedOlder.subtitle, message)
        verify(!returnedOlder.enabled)
        tryCompare(returnedPager, "contentY", offset)

        tryCompare(returnedOlder, "enabled", true)
        compare(returnedOlder.title, "Retry loading older games")
        compare(historyRequests().length, requestCount)
        verify(returnedOlder.mapToItem(returnedPager, 0, returnedOlder.height).y <= returnedPager.pageHeight + 0.5)
        mouseClick(returnedOlder, returnedOlder.width / 2, returnedOlder.height / 2)
        compare(historyRequests().length, requestCount + 1)
        var retried = historyRequests().slice(-1)[0]
        compare(retried, Object.assign({}, limited, {request_id: retried.request_id}))
        endpoint.reply({type: "GameHistory", request_id: retried.request_id,
                        games: [{game_id: "oldest"}]})
        compare(returned.games.length, 21)
        compare(returned.games[20].game_id, "oldest")
        verify(!returnedOlder.visible)
    }

    function test_loadOlderGamesPreservesFiltersAndTheArchiveVisit() {
        var requestId = applyHistoryFilters("rapid")
        var games = []
        for (var i = 0; i < 20; i++) {
            games.push({game_id: "archive-" + i, opponent_name: "Opponent " + i,
                        result: "draw", speed: "rapid", rated: true})
        }
        var cursor = {until_ms: 1765526400001, seen_at_cutoff: ["archive-19"]}
        endpoint.reply({type: "GameHistory", request_id: requestId, games: games, next_cursor: cursor})
        var history = screen.item
        var pager = findChild(history, "historyList")
        var next = findChild(pager, "pageDownButton")
        var older = findChild(history, "loadOlderGamesButton")
        verify(waitForRendering(pager))
        var initialCards = archiveRows(history)
        compare(initialCards.length, 20)
        for (var page = 1; page < pager.pageCount; page++) mouseClick(next, next.width / 2, next.height / 2)
        verify(!next.enabled)
        var oldOffset = pager.contentY
        var rowBottom = older.mapToItem(pager, 0, older.height).y
        verify(rowBottom >= older.height && rowBottom <= pager.pageHeight + 0.5)

        mouseClick(older, older.width / 2, older.height / 2)
        var first = historyRequests().slice(-1)[0]
        compare(first, {type: "RequestGameHistory", request_id: first.request_id,
                        rated: true, speed: "rapid", color: "black", cursor: cursor})
        compare(older.title, "Loading older games…")
        verify(history.loadingOlder && !older.enabled)
        history.loadOlderGames()
        compare(historyRequests().slice(-1)[0].request_id, first.request_id)
        endpoint.reply({type: "GameHistoryFailed", request_id: first.request_id, message: "Try again later"})
        compare(history.games.length, 20)
        compare(history.olderLoadError, "Try again later")
        compare(older.title, "Retry loading older games")
        compare(older.subtitle, "Try again later")
        verify(!next.enabled)
        compare(pager.contentY, oldOffset)
        verify(waitForRendering(older))
        mouseClick(older, older.width / 2, older.height / 2)
        var retry = historyRequests().slice(-1)[0]
        verify(retry.request_id > first.request_id)
        compare(retry, Object.assign({}, first, {request_id: retry.request_id}))

        var olderGame = {game_id: "older-0", opponent_name: "Earlier opponent", review_supported: true,
                         your_analysis: {accuracy: 95, blunders: 1, mistakes: 2}}
        var nextCursor = {until_ms: 1765526398001}
        endpoint.reply({type: "GameHistory", request_id: first.request_id, games: [{game_id: "stale"}]})
        verify(history.loadingOlder)
        endpoint.reply({type: "GameHistory", request_id: retry.request_id,
                        games: [games[19], olderGame], next_cursor: nextCursor})
        compare(history.games.length, 21)
        compare(history.games[20].game_id, "older-0")
        compare(history.olderLoadError, "")
        tryVerify(function() { return next.enabled })
        tryCompare(pager, "contentY", oldOffset)

        var appendedCards = archiveRows(history)
        compare(appendedCards.length, 21)
        for (var rowIndex = 0; rowIndex < initialCards.length; rowIndex++) {
            verify(initialCards[rowIndex] === appendedCards[rowIndex], "Recreated archive card " + rowIndex)
        }
        var card = appendedCards[20]
        compare(findChild(card, "historyAnalysis").text, "Accuracy 95% · 1 blunders, 2 mistakes")
        pager.showPageContaining(card.y, card.height)
        verify(waitForRendering(card))
        mouseClick(card, card.width / 2, card.height / 2)
        var review = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(review.type, "RequestGameMoves")
        compare(review.game_id, olderGame.game_id)
        var requestCount = historyRequests().length
        replyWithMoves(review.request_id, "e4")
        findChild(screen.item, "reviewBackButton").clicked()
        var returned = screen.item
        compare(historyRequests().length, requestCount)
        compare(returned.games.length, 21)
        compare(returned.nextHistoryCursor, nextCursor)
        compare(returned.filterSummary(), "Rated · Rapid · Played Black")
        var restoredCards = archiveRows(returned)
        compare(restoredCards.length, 21)
        compare(findChild(restoredCards[20], "historyAnalysis").text,
                "Accuracy 95% · 1 blunders, 2 mistakes")
        returned.loadOlderGames()
        var last = historyRequests().slice(-1)[0]
        compare(last.cursor, nextCursor)
        endpoint.reply({type: "GameHistory", request_id: last.request_id, games: [{game_id: "oldest"}]})
        compare(returned.games.length, 22)
        var finalCards = archiveRows(returned)
        compare(finalCards.length, 22)
        verify(finalCards[20] === restoredCards[20])
        compare(finalCards[21].modelData.game_id, "oldest")
        verify(!findChild(returned, "loadOlderGamesButton").visible)
    }

    function test_filterChangesSupersedeAnOlderGamesRequest() {
        var first = applyHistoryFilters("rapid")
        var cursor = {until_ms: 1765526400001}
        var history = screen.item
        endpoint.reply({type: "GameHistory", request_id: first,
                        games: [{game_id: "rapid"}], next_cursor: cursor})
        history.loadOlderGames()
        var older = history.pendingHistoryRequest
        verify(older > first)
        var filtered = applyHistoryFilters("blitz")
        verify(filtered > older)
        verify(historyRequests().slice(-1)[0].cursor === undefined)
        endpoint.reply({type: "GameHistoryFailed", request_id: older, message: "Stale error"})
        endpoint.reply({type: "GameHistory", request_id: older,
                        games: [{game_id: "stale"}], next_cursor: cursor})
        verify(history.loading)
        compare(history.games.length, 0)
        compare(history.olderLoadError, "")
        endpoint.reply({type: "GameHistory", request_id: filtered, games: [{game_id: "blitz"}]})
        compare(history.games[0].game_id, "blitz")
        verify(!findChild(history, "loadOlderGamesButton").visible)
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

    function test_explorePreservesSiblingLinesAndReopensTheSavedTree() {
        var reviewId = choose("saved-branches")
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: [], fens: [startFen],
                        variation_storage: true})
        var review = screen.item
        var explore = findChild(review, "beginExplorationButton")
        compare(endpoint.sentMessages.slice(-1)[0], {type: "RequestReviewVariations", review_id: reviewId})
        verify(!explore.enabled)
        endpoint.reply({type: "ReviewVariations", review_id: reviewId + 1, variations: {positions: []}})
        verify(!explore.enabled)
        endpoint.reply({type: "ReviewVariations", review_id: reviewId, variations: {positions: []}})
        verify(explore.enabled)
        explore.clicked()

        var e4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        var e5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var d4 = "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1"
        var firstMoves = [{from: "e2", to: "e4"}, {from: "d2", to: "d4"}]
        function position(fen, legal) {
            endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                            requested_fen: fen, fen: fen, legal_moves: legal})
        }
        function move(from, to, san, fen, legal) {
            verify(review.requestExplorationMove(from, to))
            endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                            from_fen: review.exploreFen, san: san, fen: fen, legal_moves: legal})
            var saved = endpoint.sentMessages.slice(-1)[0]
            compare(saved.type, "SaveReviewVariations")
            return saved
        }
        position(startFen, firstMoves)
        var first = move("e2", "e4", "e4", e4, [{from: "e7", to: "e5"}])
        move("e7", "e5", "e5", e5, [])
        var previous = findChild(review, "previousVariationPositionButton")
        previous.clicked()
        compare(review.variationMoves, ["e4"])
        previous.clicked()
        position(startFen, firstMoves)
        var fork = move("d2", "d4", "d4", d4, [])
        var snapshot = {positions: [{ply: 0, fen: startFen, nodes: [
            {parent: null, san: "e4", fen: e4},
            {parent: 0, san: "e5", fen: e5},
            {parent: null, san: "d4", fen: d4}
        ]}]}
        compare(fork.variations, snapshot)
        endpoint.reply({type: "ReviewVariationsSaveFailed", review_id: reviewId,
                        request_id: fork.request_id, message: "Could not save variations."})
        endpoint.reply({type: "ReviewVariationsSaved", review_id: reviewId, request_id: first.request_id})
        compare(review.variationSaveError, "Could not save variations.")

        var lines = findChild(review, "showVariationsButton")
        verify(waitForRendering(lines))
        mouseClick(lines, lines.width / 2, lines.height / 2)
        var dialog = findChild(review, "variationDialog")
        verify(dialog.visible)
        var retry = findChild(dialog, "retrySavingVariationsButton")
        verify(retry.visible && retry.enabled)
        retry.clicked()
        var retried = endpoint.sentMessages.slice(-1)[0]
        compare(retried.variations, snapshot)
        verify(retried.request_id > fork.request_id)
        endpoint.reply({type: "ReviewVariationsSaved", review_id: reviewId, request_id: retried.request_id})
        compare(review.variationSaveError, "")
        var originalLine = findChild(dialog, "variationLine-1")
        compare(originalLine.title, "e4 e5")
        compare(findChild(dialog, "variationLine-2").title, "d4")
        verify(waitForRendering(originalLine))
        mouseClick(originalLine, originalLine.width / 2, originalLine.height / 2)
        verify(!dialog.visible)
        compare(review.currentFen(), e5)
        compare(review.variationMoves, ["e4", "e5"])
        compare(endpoint.sentMessages.slice(-1)[0].fen, e5)

        review.stopExploration()
        review.beginExploration()
        position(startFen, firstMoves)
        compare(review.currentFen(), startFen)
        lines.clicked()
        compare(findChild(dialog, "variationLine-1").title, "e4 e5")
        compare(findChild(dialog, "variationLine-2").title, "d4")

        var back = findChild(review, "reviewBackButton")
        back.clicked()
        reviewId = choose("saved-branches")
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: [], fens: [startFen],
                        variation_storage: true})
        review = screen.item
        compare(endpoint.sentMessages.slice(-1)[0], {type: "RequestReviewVariations", review_id: reviewId})
        endpoint.reply({type: "ReviewVariations", review_id: reviewId, variations: snapshot})
        review.beginExploration()
        position(startFen, firstMoves)
        findChild(review, "showVariationsButton").clicked()
        var secondLine = findChild(review, "variationLine-2")
        compare(secondLine.title, "d4")
        secondLine.clicked()
        compare(review.variationMoves, ["d4"])
        compare(review.currentFen(), d4)
    }

    function test_exploreRecoversSavedLinesWithoutLosingLocalMoves() {
        var reviewId = choose("recover-branches")
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: [], fens: [startFen],
                        variation_storage: true})
        var review = screen.item
        var failure = {type: "ReviewVariationsLoadFailed", review_id: reviewId,
                       message: "Could not load saved variations."}
        endpoint.reply(failure)
        review.beginExploration()

        var e4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        var e5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var c5 = "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        var d4 = "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1"
        endpoint.reply({type: "AnalysisPosition", request_id: review.pendingAnalysisRequestId,
                        requested_fen: startFen, fen: startFen, legal_moves: [{from: "e2", to: "e4"}]})
        verify(review.requestExplorationMove("e2", "e4"))
        endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                        from_fen: startFen, san: "e4", fen: e4, legal_moves: [{from: "c7", to: "c5"}]})
        verify(review.requestExplorationMove("c7", "c5"))
        endpoint.reply({type: "AnalysisMove", request_id: review.pendingAnalysisRequestId,
                        from_fen: e4, san: "c5", fen: c5, legal_moves: []})
        compare(review.variationMoves, ["e4", "c5"])
        compare(endpoint.sentMessages.slice(-1)[0].type, "MakeAnalysisMove")

        findChild(review, "showVariationsButton").clicked()
        var dialog = findChild(review, "variationDialog")
        var retry = findChild(dialog, "retryLoadingVariationsButton")
        verify(retry && retry.visible && retry.enabled, "failed loading should offer a retry")
        verify(waitForRendering(retry))
        mouseClick(retry, retry.width / 2, retry.height / 2)
        compare(endpoint.sentMessages.slice(-1)[0], {type: "RequestReviewVariations", review_id: reviewId})
        verify(!retry.enabled)
        endpoint.reply(failure)
        verify(retry.visible && retry.enabled)
        compare(review.variationMoves, ["e4", "c5"])
        retry.clicked()

        endpoint.reply({type: "ReviewVariations", review_id: reviewId + 1, variations: {positions: []}})
        verify(!retry.enabled)
        endpoint.reply({type: "ReviewVariations", review_id: reviewId, variations: {positions: [
            {ply: 0, fen: startFen, nodes: [
                {parent: null, san: "d4", fen: d4},
                {parent: null, san: "e4", fen: e4},
                {parent: 1, san: "e5", fen: e5}
            ]},
            {ply: 1, fen: e4, nodes: [{parent: null, san: "e5", fen: e5}]}
        ]}})
        verify(!retry.visible)
        compare(review.variationLoadError, "")
        compare(review.currentFen(), c5)
        compare(review.variationMoves, ["e4", "c5"])
        var saved = endpoint.sentMessages.slice(-1)[0]
        compare(saved.type, "SaveReviewVariations")
        compare(saved.review_id, reviewId)
        compare(saved.variations, {positions: [
            {ply: 0, fen: startFen, nodes: [
                {parent: null, san: "e4", fen: e4},
                {parent: 0, san: "c5", fen: c5},
                {parent: null, san: "d4", fen: d4},
                {parent: 0, san: "e5", fen: e5}
            ]},
            {ply: 1, fen: e4, nodes: [{parent: null, san: "e5", fen: e5}]}
        ]})
        endpoint.reply({type: "ReviewVariationsSaved", review_id: reviewId, request_id: saved.request_id})
        var recovered = findChild(dialog, "variationLine-3")
        compare(recovered.title, "e4 e5")
        recovered.clicked()
        compare(review.variationMoves, ["e4", "e5"])
        compare(review.currentFen(), e5)
    }

    function test_openingExplorerLoadsOnDemandAndTriesAContinuation() {
        var reviewId = choose("openings")
        var e4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        var e5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: ["e4"], fens: [startFen, e4]})
        var review = screen.item
        function requests() {
            return endpoint.sentMessages.filter(function(message) { return message.type === "RequestOpeningExplorer" })
        }
        function openingReply(request, type, fields) {
            endpoint.reply(Object.assign({type: type, request_id: request.request_id, review_id: request.review_id,
                                          database: request.database, fen: request.fen}, fields))
        }
        review.goNext()
        compare(requests().length, 0)
        review.showReviewOptions = true
        var open = findChild(review, "openOpeningExplorerButton")
        verify(open && waitForRendering(open))
        mouseClick(open, open.width / 2, open.height / 2)
        var dialog = findChild(review, "openingExplorerDialog")
        var selector = findChild(dialog, "openingDatabaseSelector")
        var status = findChild(dialog, "openingExplorerStatus")
        verify(dialog.visible)
        compare(status.text, "Loading opening statistics…")
        var first = requests()[0]
        compare(first, {type: "RequestOpeningExplorer", request_id: first.request_id, review_id: reviewId,
                        database: "masters", fen: e4, root_fen: startFen, played_san: ["e4"]})

        selector.selected("lichess")
        var rated = requests()[1]
        compare(rated.database, "lichess")
        var data = {white: 5, draws: 2, black: 3, opening: {eco: "B00", name: "King's Pawn Game"},
                    moves: [{uci: "e7e5", san: "e5", white: 4, draws: 2, black: 2}]}
        openingReply(first, "OpeningExplorer", {data: data})
        compare(status.text, "Loading opening statistics…")
        openingReply(rated, "OpeningExplorerFailed",
                     {message: "Lichess limited opening statistics requests.", retry_after_ms: 400})
        var retry = findChild(dialog, "openingExplorerRetry")
        verify(retry.visible && !retry.enabled)
        compare(retry.text, "Retry available shortly")
        selector.selected("masters")
        compare(requests().length, 2)
        selector.selected("lichess")
        compare(requests().length, 2)
        tryCompare(retry, "enabled", true)
        compare(requests().length, 2)
        retry.clicked()
        compare(requests().length, 3)
        var retried = requests()[2]
        compare(retried.database, "lichess")
        openingReply(retried, "OpeningExplorer", {data: data})
        compare(findChild(dialog, "openingName").text, "B00 · King's Pawn Game")
        compare(status.text, "10 games")
        var move = findChild(dialog, "openingMove-e7e5")
        compare(move.subtitle, "8 games\n50% White · 25% Draw · 25% Black")
        verify(!findChild(move, "menuRowSubtitle").truncated)

        findChild(dialog, "closeOpeningExplorerButton").clicked()
        open.clicked()
        compare(requests().length, 3)
        verify(dialog.visible)
        verify(waitForRendering(move))
        mouseClick(move, move.width / 2, move.height / 2)
        verify(!dialog.visible && review.exploreMode)
        var position = endpoint.sentMessages.slice(-1)[0]
        compare(position.type, "RequestAnalysisPosition")
        compare(position.fen, e4)
        endpoint.reply({type: "AnalysisPosition", request_id: position.request_id,
                        requested_fen: e4, fen: e4, legal_moves: [{from: "e7", to: "e5"}]})
        var continuation = endpoint.sentMessages.slice(-1)[0]
        compare(continuation, {type: "MakeAnalysisMove", request_id: continuation.request_id,
                               fen: e4, from: "e7", to: "e5", promotion: null})
        endpoint.reply({type: "AnalysisMove", request_id: continuation.request_id,
                        from_fen: e4, fen: e5, san: "e5", legal_moves: []})
        compare(review.variationMoves, ["e5"])
        compare(review.currentFen(), e5)
        compare(requests().length, 3)

        open.clicked()
        var next = requests()[3]
        compare(next.played_san, ["e4", "e5"])
        compare(next.fen, e5)
        findChild(review, "reviewBackButton").clicked()
        tryVerify(function() {
            return endpoint.sentMessages.some(function(message) {
                return message.type === "CancelOpeningExplorer" && message.review_id === reviewId
            })
        })
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

    function test_cloudCooldownBlocksRetriesAcrossPositionsAndReviews() {
        var reviewId = choose("rate-limited-cloud")
        var afterE4 = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: ["e4"], fens: [startFen, afterE4]})
        var review = screen.item
        review.requestCloudEvaluation()
        var cached = endpoint.sentMessages.slice(-1)[0]
        endpoint.reply({type: "CloudEvaluation", request_id: cached.request_id, requested_fen: startFen,
                        evaluation: {depth: 24, knodes: 50, eval_cp: 10}})
        review.goNext()
        review.requestCloudEvaluation()
        var limited = endpoint.sentMessages.slice(-1)[0]
        endpoint.reply({type: "CloudEvaluationFailed", request_id: limited.request_id,
                        requested_fen: afterE4, message: "Lichess is limiting cloud evaluations.",
                        retry_after_ms: 60000})
        verify(!review.canRequestCloudEvaluation, "the rate-limited position should wait before retry")
        var deadline = app.cloudEvaluationRetryAt
        endpoint.reply({type: "CloudEvaluationFailed", request_id: limited.request_id,
                        requested_fen: afterE4, message: "Try again later.", retry_after_ms: 1})
        compare(app.cloudEvaluationRetryAt, deadline)

        var count = endpoint.sentMessages.length
        review.requestCloudEvaluation()
        compare(endpoint.sentMessages.length, count)
        review.goPrev()
        compare(review.currentCloudEvaluation().depth, 24)

        findChild(review, "reviewBackButton").clicked()
        reviewId = choose("another-cloud-review")
        endpoint.reply({type: "GameMoves", request_id: reviewId, moves: [], fens: [startFen]})
        review = screen.item
        verify(!review.canRequestCloudEvaluation)
        review.showReviewOptions = true
        var button = findChild(review, "requestCloudEvaluationButton")
        verify(button.visible && !button.enabled)
        compare(button.text, "Cloud evaluation paused")
        count = endpoint.sentMessages.length
        review.requestCloudEvaluation()
        compare(endpoint.sentMessages.length, count)

        app.cloudEvaluationRetryAt = Date.now() + 50
        tryVerify(function() { return button.enabled })
        verify(button.visible)
        button.clicked()
        var resumed = endpoint.sentMessages.slice(-1)[0]
        compare(resumed.type, "RequestCloudEvaluation")
        compare(resumed.review_id, reviewId)
        compare(resumed.fen, startFen)
    }

    function test_cloudLinePagesEveryMoveWithoutChangingTheBoard_data() {
        return [
            {tag: "Paper Pro Move", width: 954, height: 1696},
            {tag: "Paper Pro", width: 1620, height: 2160}
        ]
    }

    function test_cloudLinePagesEveryMoveWithoutChangingTheBoard(data) {
        width = data.width
        height = data.height
        var base = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 37"
        var afterE5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 38"
        var requestId = choose("paged-cloud-line")
        endpoint.reply({type: "GameMoves", request_id: requestId, fens: [base, afterE5], moves: ["e5"]})
        var review = screen.item
        var open = findChild(review, "cloudBestLineButton")
        verify(!open.visible)
        review.requestCloudEvaluation()
        var cloud = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        var moves = []
        for (var index = 0; index < 12; index++) moves = moves.concat(["Nc6", "Nf3", "Nb8", "Ng1"])
        endpoint.reply({type: "CloudEvaluation", request_id: cloud.request_id, requested_fen: cloud.fen,
                        evaluation: {depth: 38, knodes: 42000, eval_cp: 55, best_line: moves}})
        verify(open.visible)
        verify(waitForRendering(review))
        var square = findChild(review, "boardSquare-a8")
        var boardOrigin = square.mapToItem(review, 0, 0)
        mouseClick(open, open.width / 2, open.height / 2)
        var dialog = findChild(review, "cloudBestLineDialog")
        verify(dialog && dialog.visible)
        var pager = findChild(dialog, "dialogPager")
        var close = findChild(dialog, "closeCloudBestLineButton")
        tryVerify(function() { return pager.pageCount > 1 })
        compare(pager.currentPage, 1)
        var seen = {}
        var rows = []
        function collectRows(item) {
            if (item.objectName === "cloudMoveRow") rows.push(item)
            for (var i = 0; i < item.children.length; i++) collectRows(item.children[i])
        }
        collectRows(pager)
        compare(rows.length, 25)
        var next = findChild(pager, "pageDownButton")
        for (var page = 1; page <= pager.pageCount; page++) {
            verify(close.visible)
            var closeY = close.mapToItem(review, 0, 0).y
            verify(closeY >= 0 && closeY + close.height <= review.height)
            for (var row = 0; row < rows.length; row++) {
                var item = rows[row]
                var y = item.mapToItem(pager, 0, 0).y
                if (y < -0.5 || y + item.height > pager.pageHeight + 0.5) continue
                compare(item.moveNumber, 37 + row)
                var white = moves[row * 2 - 1]
                var black = moves[row * 2]
                if (white) compare(item.whiteMove.san, white)
                else compare(item.whiteMove, null)
                if (black) compare(item.blackMove.san, black)
                else compare(item.blackMove, null)
                verify(!item.selectionEnabled)
                seen[row] = true
            }
            if (page < pager.pageCount) mouseClick(next, next.width / 2, next.height / 2)
        }
        compare(Object.keys(seen).length, rows.length)
        compare(pager.currentPage, pager.pageCount)
        mouseClick(close, close.width / 2, close.height / 2)
        tryVerify(function() { return findChild(review, "cloudBestLineDialog") === null })
        compare(review.currentFen(), base)
        compare(square.mapToItem(review, 0, 0), boardOrigin)

        mouseClick(open, open.width / 2, open.height / 2)
        dialog = findChild(review, "cloudBestLineDialog")
        compare(findChild(dialog, "dialogPager").currentPage, 1)
        review.goNext()
        compare(review.currentFen(), afterE5)
        verify(!open.visible)
        tryVerify(function() { return findChild(review, "cloudBestLineDialog") === null })
        review.requestCloudEvaluation()
        cloud = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        endpoint.reply({type: "CloudEvaluation", request_id: cloud.request_id, requested_fen: cloud.fen,
                        evaluation: {depth: 19, knodes: 50, eval_cp: 10, best_line: []}})
        compare(review.cloudEvaluationPhase, "ready")
        verify(!open.visible)
        review.goPrev()
        verify(open.visible)
        verify(!review.showCloudLine)
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

    function test_liveClockCadenceAtExactAges_data() {
        return [
            {tag: "main clock at one minute", mainMs: 60400, firstMoveMs: null,
             boundaryMs: 60000, afterInterval: 5000, before: "1:00", after: "0:59", late: "0:57"},
            {tag: "main clock at fifteen seconds", mainMs: 15400, firstMoveMs: null,
             boundaryMs: 15000, afterInterval: 1000, before: "0:15", after: "0:14", late: "0:12"},
            {tag: "first move at fifteen seconds", mainMs: 600000, firstMoveMs: 15400,
             boundaryMs: 15000, afterInterval: 1000, before: "Move in ~16s",
             after: "Move in ~15s", late: "Move in ~13s"}
        ]
    }

    function openClockCadenceGame(data) {
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
        return {board: board, snapshot: snapshot, label: label}
    }

    function test_liveClockCadenceAtExactAges(data) {
        var game = openClockCadenceGame(data)
        var board = game.board
        var receivedAt = board.liveClock.receivedAt

        // Controlled ages cover exact boundaries that fixed waits can skip and a broad deadline can't distinguish.
        board.clockNowMs = receivedAt
        compare(board.clockRefreshIntervalMs(), 1000)
        compare(game.label.text, data.before)
        board.clockNowMs = receivedAt + 999
        compare(board.clockRefreshIntervalMs(), 1)
        compare(game.label.text, data.before)
        board.clockNowMs = receivedAt + 1000
        compare(board.clockRefreshIntervalMs(), data.afterInterval)
        compare(game.label.text, data.after)
        board.clockNowMs = receivedAt + 3000
        compare(game.label.text, data.late)
        compare(board.displayClockFor("black"), 600000)
    }

    function test_liveClockTimerResyncAndCatchUp_data() {
        return test_liveClockCadenceAtExactAges_data()
    }

    function test_liveClockTimerResyncAndCatchUp(data) {
        var game = openClockCadenceGame(data)
        var board = game.board
        var snapshot = game.snapshot
        wait(650)
        endpoint.reply(snapshot)
        compare(game.label.text, data.before)
        var firstPulseAge = null
        var recordPulseAge = function() {
            if (firstPulseAge === null) firstPulseAge = Date.now() - board.liveClock.receivedAt
        }
        board.clockPulseChanged.connect(recordPulseAge)
        tryVerify(function() { return board.activeCountdownMs <= data.boundaryMs }, 4500)
        board.clockPulseChanged.disconnect(recordPulseAge)
        verify(firstPulseAge !== null && firstPulseAge >= 850,
               "First timer pulse after the resync was at " + firstPulseAge + " ms")
        verify(game.label.text !== data.before)
        compare(board.displayClockFor("black"), 600000)

        snapshot.first_move_time_ms = null
        snapshot.white_time_ms = 10000
        snapshot.outcome = {result: "draw", reason: "Agreement"}
        endpoint.reply(snapshot)
        verify(board.gameOver)
        var pulse = board.clockPulse
        wait(1250)
        compare(board.clockPulse, pulse)
    }

    function test_finalFractionFitsTheRenderedClockChip_data() {
        return [
            {tag: "your turn on Paper Pro Move", width: 954, height: 1696, turn: "white", ms: 450},
            {tag: "opponent turn on Paper Pro", width: 1620, height: 2160, turn: "black", ms: 900}
        ]
    }

    function test_finalFractionFitsTheRenderedClockChip(data) {
        width = data.width
        height = data.height
        app.openGame("active")
        var yourTurn = data.turn === "white"
        var snapshot = boardState("active")
        snapshot.initial_clock_ms = 600000
        snapshot.turn = data.turn
        if (!yourTurn) {
            snapshot.fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
            snapshot.position_history = [startFen, snapshot.fen]
            snapshot.move_history = ["e4"]
        }
        var key = data.turn + "_time_ms"
        snapshot[key] = data.ms
        endpoint.reply(snapshot)
        compare(app.width, data.width)
        compare(app.height, data.height)
        var board = screen.item
        var bar = findChild(board, yourTurn ? "bottomPlayerBar" : "topPlayerBar")
        var label = findChild(bar, "playerClockText")
        verify(label.visible)
        verify(bar.active)
        compare(bar.clockMs, data.ms)
        compare(label.text, "<1s")
        verify(label.x >= 0 && label.x + label.width <= label.parent.width)
        verify(label.y >= 0 && label.y + label.height <= label.parent.height)

        snapshot[key] = 1000
        endpoint.reply(snapshot)
        compare(label.text, "0:01")
        snapshot[key] = 0
        endpoint.reply(snapshot)
        compare(label.text, "0:00")
    }

    function test_clockSleepsAtLocalZeroAndResumesOnNewSnapshot_data() {
        return [{tag: "main clock", firstMove: false},
                {tag: "first-move deadline", firstMove: true}]
    }

    function test_clockSleepsAtLocalZeroAndResumesOnNewSnapshot(data) {
        app.openGame("active")
        var board = screen.item
        var snapshot = boardState("active")
        snapshot.initial_clock_ms = 600000
        var key = data.firstMove ? "first_move_time_ms" : "white_time_ms"
        var remaining = function() {
            return data.firstMove ? board.displayFirstMoveTimeMs() : board.displayClockFor("white")
        }
        snapshot[key] = 400
        endpoint.reply(snapshot)
        compare(remaining(), 400)
        tryVerify(function() { return remaining() === 0 }, 2400)
        verify(!board.gameOver)
        var pulse = board.clockPulse
        wait(1250)
        compare(board.clockPulse, pulse)

        snapshot[key] = 900
        endpoint.reply(snapshot)
        compare(remaining(), 900)
        tryVerify(function() { return remaining() === 0 }, 2400)
        verify(!board.gameOver)
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
        var seek = screen.item
        var pager = findChild(seek, "seekFlickable")
        var section = findChild(seek, "playerChallengeSection")
        findChild(seek, "usernameField").text = "opponent"
        tryVerify(function() { return section.y > 0 })
        pager.moveTo(section.y)
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
        var retry = findChild(seek, "challengePlayerButton")
        tryVerify(function() {
            var y = retry.mapToItem(pager, 0, 0).y
            return y >= 0 && y + retry.height <= pager.pageHeight
        })

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

    function test_openChallengeQrFollowsTheSelectedLink_data() {
        return [{tag: "Paper Pro Move", width: 954, height: 1696, nextPage: true},
                {tag: "Paper Pro in dark mode", width: 1620, height: 2160, darkMode: true, nextPage: false}]
    }

    function test_openChallengeQrFollowsTheSelectedLink(data) {
        width = data.width
        height = data.height
        app.darkMode = data.darkMode === true
        app.navigateTo("SeekScreen.qml")
        var seek = screen.item
        var pager = findChild(seek, "seekFlickable")
        var create = findChild(seek, "openChallengeButton")
        verify(waitForRendering(seek))
        pager.showPageContaining(create.y, create.height)
        mouseClick(create, create.width / 2, create.height / 2)
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "CreateOpenChallenge")

        var url = "https://lichess.org/ovdODEHx"
        var matrices = {
            join: {size: 2, rows: ["10", "10"]},
            white: {size: 2, rows: ["01", "01"]},
            black: {size: 2, rows: ["11", "00"]}
        }
        endpoint.reply({type: "OpenChallengeCreated", request_id: request.request_id,
                        game_id: "ovdODEHx", url: url, qr_codes: matrices,
                        url_white: url + "?color=white", url_black: url + "?color=black"})
        var share = findChild(seek, "openChallengeShare")
        var qr = findChild(share, "openChallengeQr")
        var sides = findChild(share, "openChallengeSide")
        var address = findChild(share, "openChallengeUrl")
        verify(waitForRendering(share))
        tryVerify(function() {
            var top = share.mapToItem(pager, 0, 0).y
            return top >= -0.5 && top + share.height <= pager.pageHeight + 0.5
        })
        verify(qr.visible)
        compare(findChild(pager, "pageDownButton").enabled, data.nextPage)
        compare(qr.lightColor, "#ffffff")
        compare(qr.darkColor, "#000000")
        compare(address.text, url)
        compare(qr.rows, matrices.join.rows)

        mouseClick(sides, sides.width / 2, sides.height / 2)
        compare(address.text, url + "?color=white")
        compare(qr.rows, matrices.white.rows)
        mouseClick(sides, sides.width * 5 / 6, sides.height / 2)
        compare(address.text, url + "?color=black")
        compare(qr.rows, matrices.black.rows)
        mouseClick(sides, sides.width / 6, sides.height / 2)
        compare(address.text, url)
        compare(qr.rows, matrices.join.rows)
    }

    function test_computerActionStatesItsModeWithRatedSelected_data() {
        return [
            {tag: "Paper Pro Move", width: 954, height: 1696, color: "white", colorX: 1 / 6},
            {tag: "Paper Pro", width: 1620, height: 2160, color: "black", colorX: 1 / 2}
        ]
    }

    function test_computerActionStatesItsModeWithRatedSelected(data) {
        width = data.width
        height = data.height
        app.navigateTo("SeekScreen.qml")
        var seek = screen.item
        var pager = findChild(seek, "seekFlickable")
        verify(waitForRendering(seek))
        var rating = findChild(seek, "gameTypeControl")
        var label = findChild(seek, "playerGameTypeLabel")
        verify(label.visible)
        compare(label.text, "Games with other players")
        mouseClick(rating, rating.width * 3 / 4, rating.height / 2)
        compare(rating.value, "rated")
        var color = findChild(seek, "colorControl")
        mouseClick(color, color.width * data.colorX, color.height / 2)
        compare(color.value, data.color)

        findChild(seek, "minutesField").text = "7"
        findChild(seek, "incrementField").text = "3"
        findChild(seek, "aiLevelField").text = "6"
        var section = findChild(seek, "computerSection")
        pager.showPageContaining(section.y, section.height)
        var start = findChild(section, "computerGameButton")
        verify(waitForRendering(start))
        compare(start.text, "Start casual computer game")
        verify(start.width >= start.naturalWidth)
        mouseClick(start, start.width / 2, start.height / 2)
        var first = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(first, {type: "ChallengeAi", request_id: seek.matchRequestId,
                        minutes: 7, increment: 3, level: 6, color: data.color})
        verify(!start.enabled)
        var pageOffset = pager.contentY
        endpoint.reply({type: "MatchCreationFailed", request_id: first.request_id, message: "Try again"})
        compare(rating.value, "rated")
        compare(start.text, "Start casual computer game")
        verify(start.enabled)
        verify(waitForRendering(start))
        compare(pager.contentY, pageOffset)
        mouseClick(start, start.width / 2, start.height / 2)
        var retry = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        verify(retry.request_id > first.request_id)
        compare(retry, Object.assign({}, first, {request_id: retry.request_id}))
    }

    function test_setupErrorKeepsRetryVisible_data() {
        return [
            {tag: "computer rejection after a share link", width: 954, height: 1696, share: true,
             button: "computerGameButton", request: "ChallengeAi", failure: "MatchCreationFailed"},
            {tag: "computer level validation after a share link", width: 954, height: 1696, share: true,
             button: "computerGameButton", request: null},
            {tag: "open challenge rejection", width: 1620, height: 2160,
             button: "openChallengeButton", request: "CreateOpenChallenge", failure: "MatchCreationFailed"},
            {tag: "matchmaking rejection", width: 954, height: 1696,
             button: "findOpponentButton", request: "CreateSeek", failure: "SeekFailed"}
        ]
    }

    function test_setupErrorKeepsRetryVisible(data) {
        width = data.width
        height = data.height
        app.navigateTo("SeekScreen.qml")
        var seek = screen.item
        var pager = findChild(seek, "seekFlickable")
        var action = findChild(seek, data.button)
        verify(waitForRendering(seek))
        if (data.share) {
            var create = findChild(seek, "openChallengeButton")
            pager.showPageContaining(create.y, create.height)
            mouseClick(create, create.width / 2, create.height / 2)
            var share = endpoint.sentMessages[endpoint.sentMessages.length - 1]
            compare(share.type, "CreateOpenChallenge")
            var url = "https://lichess.org/open0001"
            endpoint.reply({type: "OpenChallengeCreated", game_id: "open0001", request_id: share.request_id,
                            url: url, url_white: url + "?color=white", url_black: url + "?color=black",
                            qr_codes: {join: {size: 2, rows: ["10", "01"]}}})
            verify(waitForRendering(action))
            var next = findChild(pager, "pageDownButton")
            mouseClick(next, next.width / 2, next.height / 2)
            verify(waitForRendering(action))
        }
        var computerLevel = findChild(seek, "aiLevelField")
        if (!data.request) computerLevel.text = "0"

        function actionInView() {
            var y = action.mapToItem(pager, 0, 0).y
            return action.visible && y >= -0.5 && y + action.height <= pager.pageHeight + 0.5
        }
        verify(actionInView())
        var sent = endpoint.sentMessages.length
        mouseClick(action, action.width / 2, action.height / 2)
        var reason = "Lichess could not create the game. The server is temporarily unable to accept " +
            "this request. Please try again after the service recovers."
        if (data.request) {
            var first = endpoint.sentMessages[sent]
            compare(first.type, data.request)
            endpoint.reply({type: data.failure, request_id: first.request_id + 100, message: reason})
            compare(seek.formError, "")
            endpoint.reply({type: data.failure, request_id: first.request_id, message: reason})
            sent += 1
        } else {
            reason = "Computer level must be a whole number from 1 to 8."
        }
        compare(endpoint.sentMessages.length, sent)
        var error = findChild(seek, "seekErrorText")
        verify(waitForRendering(error))
        verify(error.visible)
        compare(error.text, reason)
        verify(action.enabled)
        tryVerify(actionInView)
        if (!data.request) computerLevel.text = "4"
        mouseClick(action, action.width / 2, action.height / 2)
        compare(endpoint.sentMessages[sent].type, data.request || "ChallengeAi")
    }

    function test_computerFailureRespectsPaging_data() {
        return [{tag: "during request", beforeReply: true},
                {tag: "after reply", beforeReply: false}]
    }

    function test_computerFailureRespectsPaging(data) {
        app.navigateTo("SeekScreen.qml")
        var seek = screen.item
        var pager = findChild(seek, "seekFlickable")
        verify(waitForRendering(seek))
        pager.pageDown()
        var action = findChild(seek, "computerGameButton")
        verify(waitForRendering(action))
        mouseClick(action, action.width / 2, action.height / 2)
        var request = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(request.type, "ChallengeAi")
        var failure = {type: "MatchCreationFailed", request_id: request.request_id, message: "Please retry"}
        if (!data.beforeReply) endpoint.reply(failure)
        for (var page = pager.pageCount; page > 0 && pager.contentY > 0; page--) pager.pageUp()
        compare(pager.contentY, 0)
        if (data.beforeReply) endpoint.reply(failure)
        var error = findChild(seek, "seekErrorText")
        verify(waitForRendering(error))
        compare(error.text, "Please retry")
        compare(pager.contentY, 0)
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
        var error = findChild(screen.item, "seekErrorText")
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

    function test_inputFieldPlaceholderTracksEditing_data() {
        return [
            {tag: "username light", dark: false, password: false},
            {tag: "username dark", dark: true, password: false},
            {tag: "token light", dark: false, password: true},
            {tag: "token dark", dark: true, password: true}
        ]
    }

    function test_inputFieldPlaceholderTracksEditing(data) {
        app.darkMode = data.dark
        if (data.password) {
            endpoint.reply({type: "AuthenticationRequired"})
            var login = screen.item
            verify(waitForRendering(login))
            var manual = findChild(login, "manualEntryButton")
            mouseClick(manual, manual.width / 2, manual.height / 2)
        } else {
            app.navigateTo("SeekScreen.qml")
            var seek = screen.item
            verify(waitForRendering(seek))
            findChild(seek, "seekFlickable").pageDown()
        }
        var field = findChild(screen.item, data.password ? "tokenField" : "usernameField")
        var done = findChild(screen.item, data.password ? "tokenKeyboardDoneButton" : "usernameKeyboardDoneButton")
        var hint = findChild(field, "textFieldPlaceholder")
        verify(hint)
        verify(waitForRendering(field))
        verify(hint.visible)
        compare(hint.text, data.password ? "lip_..." : "opponent username")
        compare(hint.color, field.placeholderTextColor)
        compare(hint.mapToItem(field, 0, 0), Qt.point(field.leftPadding, field.topPadding))
        compare(hint.width, field.width - field.leftPadding - field.rightPadding)
        verify(!hint.truncated)

        mouseClick(field, field.width / 2, field.height / 2)
        verify(field.activeFocus && hint.visible)
        keyClick(Qt.Key_A)
        compare(field.text, "a")
        verify(!hint.visible)
        keyClick(Qt.Key_Backspace)
        compare(field.text, "")
        verify(hint.visible)

        keyClick(Qt.Key_A)
        verify(waitForRendering(done))
        mouseClick(done, done.width / 2, done.height / 2)
        verify(!field.activeFocus && !hint.visible)
        compare(field.text, "a")
        if (data.password) verify(field.displayText !== field.text)
        field.clear()
        verify(hint.visible)
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
        compare(authEndpoint.sentMessages.filter(function(message) {
            return message.type === "RequestSettings"
        }).length, 1)
        authEndpoint.reply({type: "AuthenticationCheckFailed", message: "old error"})
        verify(String(startup.source).endsWith("HomeScreen.qml"))
    }

    function test_startupRestoresDarkModeBeforeSignInAndAcrossScreens() {
        var reopened = createTemporaryObject(Qt.createComponent("../ui/main.qml"), this)
        var reopenedEndpoint = findChild(reopened, "testAppLoadEndpoint")
        var reopenedScreen = findChild(reopened, "screenLoader")
        reopenedEndpoint.reply({type: "SettingsState", dark_mode: true, board_theme: "green", piece_set: "merida"})
        verify(reopenedScreen.item.darkMode)
        reopenedEndpoint.reply({type: "AuthenticationRequired"})
        verify(String(reopenedScreen.source).endsWith("LoginScreen.qml"))
        verify(reopenedScreen.item.darkMode)
        reopenedEndpoint.reply({type: "TokenVerified", username: "player"})
        verify(String(reopenedScreen.source).endsWith("HomeScreen.qml"))
        verify(reopenedScreen.item.darkMode)
        verify(!reopenedEndpoint.sentMessages.some(function(message) {
            return message.type === "RequestSettings"
        }))

        reopened.openGame("dark-game")
        reopenedEndpoint.reply(boardState("dark-game"))
        verify(reopenedScreen.item.darkMode)
        compare(reopenedScreen.item.boardTheme, "green")
        compare(reopenedScreen.item.pieceSet, "merida")
        reopened.openGameReview("dark-game", {game_id: "dark-game"})
        var request = reopenedEndpoint.sentMessages[reopenedEndpoint.sentMessages.length - 1]
        reopenedEndpoint.reply({type: "GameMoves", request_id: request.request_id,
                               fens: [startFen], moves: []})
        verify(reopenedScreen.item.darkMode)
        compare(reopenedScreen.item.boardTheme, "green")
        compare(reopenedScreen.item.pieceSet, "merida")
    }

    function test_darkModeToggleSavesAndUsesPersistedAppearanceOnFailure() {
        endpoint.reply({type: "SettingsState", dark_mode: false, board_theme: "green", piece_set: "merida"})
        app.navigateTo("SettingsScreen.qml")
        var settings = screen.item
        var toggle = findChild(settings, "darkModeSetting")
        var button = findChild(toggle, "settingsToggleButton")
        verify(waitForRendering(settings))
        var sent = endpoint.sentMessages.length
        mouseClick(button, button.width / 2, button.height / 2)
        verify(toggle.value)
        compare(endpoint.sentMessages.length, sent + 1)
        var save = endpoint.sentMessages[sent]
        compare(save.type, "SaveSettings")
        compare(save.dark_mode, true)
        compare(save.board_theme, "green")
        compare(save.piece_set, "merida")

        app.openGame("settings-save-board")
        endpoint.reply(boardState("settings-save-board"))
        verify(screen.item.darkMode)
        sent = endpoint.sentMessages.length
        endpoint.reply({type: "SettingsSaveFailed", request_id: save.request_id,
                        message: "Storage unavailable", dark_mode: false,
                        board_theme: "green", piece_set: "merida"})
        compare(endpoint.sentMessages.length, sent)
        verify(!screen.item.darkMode)
        app.navigateTo("SettingsScreen.qml")
        settings = screen.item
        verify(!findChild(settings, "darkModeSetting").value)
        compare(settings.boardTheme, "green")
        compare(settings.pieceSet, "merida")
        compare(settings.saveError, "Storage unavailable")
        findChild(settings, "dismissSettingsSaveErrorButton").clicked()
        compare(settings.saveError, "")
    }

    function test_settingsRepliesCannotEraseNewerEdits_data() {
        return [{tag: "request IDs", scoped: true}, {tag: "legacy ordered replies", scoped: false}]
    }

    function test_settingsRepliesCannotEraseNewerEdits(data) {
        endpoint.reply({type: "SettingsState", board_theme: "brown", piece_set: "cburnett"})
        app.navigateTo("SettingsScreen.qml")
        app.setBoardTheme("green")
        var first = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        app.setPieceSet("merida")
        var second = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        verify(first.request_id < second.request_id)

        function acknowledge(save) {
            var packet = Object.assign({}, save, {type: "SettingsState"})
            if (!data.scoped) {
                delete packet.request_id
                delete packet.dark_mode
            }
            endpoint.reply(packet)
        }

        acknowledge(first)
        compare(screen.item.pieceSet, "merida")
        app.setShowCoordinates(false)
        var third = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        compare(third.piece_set, "merida")
        compare(third.show_coordinates, false)
        if (data.scoped) {
            endpoint.reply({type: "SettingsState", board_theme: "brown", piece_set: "cburnett"})
            endpoint.reply(Object.assign({}, first, {
                type: "SettingsSaveFailed", request_id: second.request_id, message: "Stale failure"
            }))
        } else {
            endpoint.reply({type: "ErrorMsg", message: "failed to save settings: stale failure"})
        }
        compare(screen.item.pieceSet, "merida")
        verify(!screen.item.showCoordinates)
        compare(screen.item.saveError, "")
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1], third)
        acknowledge(third)
        if (data.scoped) acknowledge(second)
        compare(screen.item.pieceSet, "merida")
        verify(!screen.item.showCoordinates)
    }

    function test_legacySettingsReadbackYieldsToANewerEdit() {
        endpoint.reply({type: "SettingsState", board_theme: "green", piece_set: "cburnett"})
        app.navigateTo("SettingsScreen.qml")
        app.setPieceSet("merida")
        endpoint.reply({type: "ErrorMsg", message: "failed to save settings: storage unavailable"})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1].type, "RequestSettings")
        compare(screen.item.saveError, "failed to save settings: storage unavailable")
        app.setShowCoordinates(false)
        var next = endpoint.sentMessages[endpoint.sentMessages.length - 1]
        endpoint.reply({type: "SettingsState", board_theme: "green", piece_set: "cburnett"})
        compare(screen.item.pieceSet, "merida")
        verify(!screen.item.showCoordinates)
        var acknowledged = Object.assign({}, next, {type: "SettingsState"})
        delete acknowledged.request_id
        endpoint.reply(acknowledged)
        compare(screen.item.pieceSet, "merida")
        verify(!screen.item.showCoordinates)
        compare(screen.item.saveError, "")
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

    function test_tokenOnlyAuthStaysInTokenModeAfterSignOut() {
        function qrRequests() {
            return Array.prototype.filter.call(endpoint.sentMessages, function(message) {
                return message.type === "StartLogin"
            }).length
        }
        endpoint.reply({type: "SignInOptions", qr_available: false})
        var first = qrRequests()
        endpoint.reply({type: "AuthenticationRequired"})
        verify(String(screen.source).endsWith("LoginScreen.qml"))
        compare(qrRequests(), first)
        verify(screen.item.showingTokenEntry && !screen.item.showingScanAlternative)

        findChild(screen.item, "tokenField").text = "synthetic-fixture-token"
        screen.item.saveToken()
        var request = screen.item.signInRequestId
        endpoint.reply({type: "SignInReady", request_id: request})
        compare(endpoint.sentMessages[endpoint.sentMessages.length - 1],
                {type: "CompleteSignIn", request_id: request})
        endpoint.reply({type: "TokenVerified", username: "player", request_id: request})
        verify(String(screen.source).endsWith("HomeScreen.qml"))

        endpoint.reply({type: "AuthenticationRequired"})
        compare(qrRequests(), first)
        verify(screen.item.showingTokenEntry && !screen.item.showingScanAlternative)
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
