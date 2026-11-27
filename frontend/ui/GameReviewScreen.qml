import QtQuick 2.9
import "VariationTree.js" as VariationTree

// Read-only replay of a finished game's move list, opened from
// GameHistoryScreen.
// `moves`/`fens` arrive pre-computed from the backend's GameMoves reply
// (main.qml hands them in on load, same pattern as darkMode/username) -- this
// screen does no chess logic at all, just indexes into `fens`.
Rectangle {
    id: gameReviewScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: gameReviewScreen.darkMode }
    ChessDisplay { id: chessDisplay }
    property var backendSender
    property var returnToGameHistory
    property var openPgnExport
    property string pgnGameId: ""
    property bool darkMode: false
    property string boardTheme: "brown"
    property string pieceSet: "cburnett"
    // Visual bindings preserve legal moves and clearing pulses. Alternatives are separate replay settings or filtering board state.
    property bool showCoordinates: true
    property bool highlightLastMove: true
    property bool minimalHighlights: true

    BoardStyle {
        id: boardStyle
        darkMode: gameReviewScreen.darkMode
        boardTheme: gameReviewScreen.boardTheme
        pieceSet: gameReviewScreen.pieceSet
    }

    // SAN per move, e.g. ["e4", "e5", "Nf3", ...].
    property var moves: []
    // fens[0] is the starting position; fens[i] is the position after moves[i-1].
    property var fens: []
    property bool initialInCheck: false
    // Aligned with `moves` (ply index i describes moves[i]), each possibly
    // shorter than `moves` or empty entirely (see protocol.rs's GameMoves
    // comment) -- untimed/never-analyzed games just show nothing extra.
    property var clockMs: []
    property var analysis: []
    // The HistoryGameSummary the user actually tapped (see main.qml's
    // selectGameForReview) -- GameMoves itself only carries moves/fens, so
    // this is what lets the header below show who was played and how it
    // ended instead of a contextless board.
    property var game: null
    property int reviewRequestId: 0
    // Index into `fens` currently displayed -- 0 is the start, fens.length-1 is
    // the final position. Deliberately independent of `moves`' own indexing
    // (off by one from it) rather than tracking a "current ply" separately.
    property int currentIndex: 0
    property var flashSquares: []
    // Commit pieces and markers together. Separate bindings can lag during a transition,
    // and a full-board clear spends a refresh on unchanged squares.
    property var boardAppearance: ({fen: "", previousFen: "", pieces: {}, previousPieces: {},
                                    lastMove: {}, checkedKing: ""})
    onFensChanged: gameReviewScreen.boardAppearance = gameReviewScreen.buildBoardAppearance()
    onInitialInCheckChanged: gameReviewScreen.refreshBoard()
    onMovesChanged: gameReviewScreen.refreshBoard()
    onCurrentIndexChanged: {
        if (gameReviewScreen.exploreMode) gameReviewScreen.rebaseExploration()
        else gameReviewScreen.refreshBoard()
        if (moveReveal) moveReveal.restart()
    }
    // The screen-owned timer coalesces after layout and stops on teardown.
    // Queued callbacks can outlive the review, while immediate reveal can use stale rows.
    Timer {
        id: moveReveal
        interval: 0
        onTriggered: moveList.revealCurrentMove()
    }
    Timer {
        id: boardFlashTimer
        interval: 60
        onTriggered: gameReviewScreen.flashSquares = []
    }
    // Same flip-for-black-at-bottom convenience as BoardScreen's own manualFlip,
    // just with no yourColor to XOR against here -- a finished game has no
    // "your" side baked into GameMoves, so this is the only orientation control.
    property bool manualFlip: false
    property bool exploreMode: false
    property bool showReviewOptions: false
    property bool showVariations: false
    property string exploreFen: ""
    property var exploreLegalMoves: []
    property var variationFens: []
    property var variationMoves: []
    property var reviewVariations: ({positions: []})
    property var activeVariationNode: null
    property string exploreRootFen: ""
    readonly property var activeVariation: VariationTree.position(
        reviewVariations, currentIndex, fens[currentIndex] || "")
    property string variationStoreState: ""
    property string variationLoadError: ""
    property string variationSaveError: ""
    property bool variationSnapshotFull: false
    readonly property string variationStorageError: variationStoreState === "loading"
        ? "" : variationLoadError || variationSaveError
    property int pendingVariationSaveId: 0
    readonly property string variationStartFen: variationFens[0] || ""
    readonly property var candidateRows: chessDisplay.moveRows(variationMoves, [], [], variationStartFen)
    // A normalized FEN can still be the archived move, and hiding all Explore
    // annotations would also hide the judgment when Undo returns to that move.
    readonly property var displayedArchiveAnalysis: variationMoves.length === 0
        ? analysisAt(currentIndex - 1) : null
    onVariationMovesChanged: if (moveReveal) moveReveal.restart()
    property string selectedSquare: ""
    property var pendingPromotion: null
    property string exploreStatus: ""
    // Null keeps the SAN marker while loading. False would hide it, and
    // carrying the last reply forward can mark a different position.
    property var exploreInCheck: null
    property string exploreStatusCode: "playing"
    property var nextRequestId
    property int pendingAnalysisRequestId: 0
    property string openingMoveAfterPosition: ""
    // Keep each position's state. One pending FEN forgets earlier work, and a
    // global busy flag prevents requesting another position while browsing.
    property var cloudEvaluationByFen: ({})
    readonly property string cloudFen: currentFen()
    readonly property var currentCloudState: cloudEvaluationByFen[cloudFen] || null
    readonly property string cloudEvaluationPhase: currentCloudState ? currentCloudState.phase : ""
    property bool cloudEvaluationCoolingDown: false
    readonly property bool canRequestCloudEvaluation: !cloudEvaluationCoolingDown && cloudFen.length > 0 &&
        (cloudEvaluationPhase === "" || cloudEvaluationPhase === "failed")
    readonly property var cloudBestMoves: {
        var evaluation = currentCloudEvaluation()
        return evaluation && evaluation.best_line || []
    }
    property bool showCloudLine: false
    onCloudFenChanged: showCloudLine = false
    property bool showOpeningExplorer: false
    property string openingDatabase: "masters"
    property var openingLookups: ({})
    property var pendingOpeningLookup: null
    property bool openingExplorerCoolingDown: false
    readonly property string openingPositionKey: JSON.stringify(
        [currentIndex, currentFen(), exploreMode ? variationMoves : []])
    readonly property string openingLookupKey: openingDatabase + openingPositionKey
    readonly property var currentOpeningLookup: openingLookups[openingLookupKey] || null
    readonly property bool canTryOpeningMove: pendingAnalysisRequestId === 0 && variationStoreState !== "loading"
    onOpeningPositionKeyChanged: showOpeningExplorer = false
    readonly property int coordinateGutter: 52

    Component.onDestruction: {
        if (gameReviewScreen.reviewRequestId > 0 && gameReviewScreen.backendSender &&
                Object.keys(gameReviewScreen.cloudEvaluationByFen).length > 0) {
            gameReviewScreen.backendSender({type: "CancelCloudEvaluations",
                                           review_id: gameReviewScreen.reviewRequestId})
        }
        if (gameReviewScreen.pendingOpeningLookup && gameReviewScreen.backendSender) {
            gameReviewScreen.backendSender({type: "CancelOpeningExplorer", review_id: gameReviewScreen.reviewRequestId})
        }
    }

    function currentFen() {
        if (gameReviewScreen.exploreMode && gameReviewScreen.exploreFen.length > 0) {
            return gameReviewScreen.exploreFen
        }
        if (gameReviewScreen.fens.length === 0) return ""
        var idx = Math.max(0, Math.min(gameReviewScreen.currentIndex, gameReviewScreen.fens.length - 1))
        return gameReviewScreen.fens[idx]
    }

    // Defaults to *your* own side at the bottom (via `game.your_color`, same
    // XOR-with-manualFlip pattern as BoardScreen's own yourColor) rather than
    // always white -- every reference client orients a game review around the
    // side you played, not a fixed white-at-bottom default.
    function filesRanks() {
        var youPlayedBlack = gameReviewScreen.game !== null && gameReviewScreen.game.your_color === "black"
        var showBlackAtBottom = youPlayedBlack !== gameReviewScreen.manualFlip
        if (showBlackAtBottom) {
            return {files: ["h","g","f","e","d","c","b","a"], ranks: ["1","2","3","4","5","6","7","8"]}
        }
        return {files: ["a","b","c","d","e","f","g","h"], ranks: ["8","7","6","5","4","3","2","1"]}
    }

    function squareAtBoardPoint(x, y) {
        var fileIndex = Math.floor(x / (grid.width / 8))
        var rankIndex = Math.floor(y / (grid.height / 8))
        if (fileIndex < 0 || fileIndex > 7 || rankIndex < 0 || rankIndex > 7) return ""
        return gameReviewScreen.fr.files[fileIndex] + gameReviewScreen.fr.ranks[rankIndex]
    }

    // The current and previous positions share decoded piece maps with the square delegates.
    function buildPieceMap(fen) {
        var map = {}
        if (!fen) return map
        var placement = fen.split(" ")[0]
        var rows = placement.split("/")
        for (var rankIndex = 0; rankIndex < rows.length; rankIndex++) {
            var row = rows[rankIndex]
            if (row === undefined) continue
            var col = 0
            for (var i = 0; i < row.length; i++) {
                var c = row[i]
                if (c >= '1' && c <= '8') {
                    col += parseInt(c)
                } else {
                    map[String.fromCharCode(97 + col) + (8 - rankIndex)] = c
                    col += 1
                }
            }
        }
        return map
    }

    function changedSquares(previous, current) {
        var changed = []
        for (var square in previous) {
            if (previous[square] !== current[square]) changed.push(square)
        }
        for (var newSquare in current) {
            if (previous[newSquare] === undefined) changed.push(newSquare)
        }
        return changed
    }

    function appendUniqueSquares(target, additions) {
        for (var i = 0; i < additions.length; i++) {
            if (target.indexOf(additions[i]) === -1) target.push(additions[i])
        }
    }

    function pieceMapFor(fen) {
        var appearance = gameReviewScreen.boardAppearance
        if (fen === appearance.fen) return appearance.pieces
        if (fen === appearance.previousFen) return appearance.previousPieces
        return gameReviewScreen.buildPieceMap(fen)
    }

    function buildBoardAppearance() {
        var fen = gameReviewScreen.currentFen()
        var previousFen = gameReviewScreen.previousFen()
        var pieces = gameReviewScreen.pieceMapFor(fen)
        var previousPieces = gameReviewScreen.pieceMapFor(previousFen)
        return {
            fen: fen,
            previousFen: previousFen,
            pieces: pieces,
            previousPieces: previousPieces,
            lastMove: gameReviewScreen.squareLookup(chessDisplay.moveEndpoints(previousFen, previousPieces, pieces)),
            checkedKing: gameReviewScreen.checkedKingSquare(fen, pieces)
        }
    }

    function refreshBoard() {
        var previous = gameReviewScreen.boardAppearance
        var current = gameReviewScreen.buildBoardAppearance()
        gameReviewScreen.boardAppearance = current
        if (previous.fen.length === 0 || current.fen.length === 0) return

        var dirty = gameReviewScreen.changedSquares(previous.pieces, current.pieces)
        if (gameReviewScreen.highlightLastMove) {
            gameReviewScreen.appendUniqueSquares(dirty,
                gameReviewScreen.changedSquares(previous.lastMove, current.lastMove))
        }
        if (previous.checkedKing !== current.checkedKing) {
            gameReviewScreen.appendUniqueSquares(dirty,
                [previous.checkedKing, current.checkedKing].filter(function(square) { return square.length > 0 }))
        }
        if (dirty.length === 0) return
        // Keep earlier squares active if a second transition arrives before the pulse ends.
        gameReviewScreen.appendUniqueSquares(dirty, gameReviewScreen.flashSquares)
        gameReviewScreen.flashSquares = dirty
        boardFlashTimer.restart()
    }

    readonly property var currentPieceMap: gameReviewScreen.boardAppearance.pieces

    function previousFen() {
        if (gameReviewScreen.exploreMode && gameReviewScreen.variationFens.length > 1) {
            return gameReviewScreen.variationFens[gameReviewScreen.variationFens.length - 2]
        }
        return gameReviewScreen.currentIndex > 0
            ? gameReviewScreen.fens[gameReviewScreen.currentIndex - 1]
            : ""
    }

    function pieceCodeFor(pieceChar) {
        if (pieceChar === "") return ""
        var isWhite = pieceChar === pieceChar.toUpperCase()
        return (isWhite ? "w" : "b") + pieceChar.toUpperCase()
    }

    readonly property var lastMoveSquareLookup: gameReviewScreen.boardAppearance.lastMove
    property var flashSquareLookup: gameReviewScreen.squareLookup(
        gameReviewScreen.flashSquares)
    // filesRanks() itself is cheap, but it's read by all 64 squares plus 16
    // rank/file labels every redraw, each call allocating two fresh arrays --
    // same "compute once, index many" reasoning as the piece maps above.
    property var fr: gameReviewScreen.filesRanks()

    function sideToMove() {
        return chessDisplay.sideToMove(gameReviewScreen.currentFen())
    }

    function isMovablePiece(piece) {
        if (piece === "") return false
        return gameReviewScreen.sideToMove() === "white"
            ? piece === piece.toUpperCase()
            : piece === piece.toLowerCase()
    }

    function destinationsFrom(square) {
        var out = []
        for (var i = 0; i < gameReviewScreen.exploreLegalMoves.length; i++) {
            if (gameReviewScreen.exploreLegalMoves[i].from === square) {
                out.push(gameReviewScreen.exploreLegalMoves[i].to)
            }
        }
        return out
    }

    property var selectedDestinations: gameReviewScreen.destinationsFrom(gameReviewScreen.selectedSquare)
    property var selectedDestinationLookup: gameReviewScreen.squareLookup(
        gameReviewScreen.selectedDestinations)
    readonly property string checkedSquare: gameReviewScreen.boardAppearance.checkedKing

    function squareLookup(squares) {
        var lookup = {}
        for (var i = 0; i < squares.length; i++) lookup[squares[i]] = true
        return lookup
    }

    function displayedPositionInCheck() {
        if (gameReviewScreen.exploreMode) {
            if (gameReviewScreen.exploreInCheck !== null) return gameReviewScreen.exploreInCheck
            var candidate = gameReviewScreen.variationMoves
            if (candidate.length > 0) return chessDisplay.moveGivesCheck(candidate[candidate.length - 1])
        }
        if (gameReviewScreen.currentIndex === 0) return gameReviewScreen.initialInCheck
        return chessDisplay.moveGivesCheck(gameReviewScreen.moves[gameReviewScreen.currentIndex - 1])
    }

    function checkedKingSquare(fen, pieces) {
        return gameReviewScreen.displayedPositionInCheck()
            ? chessDisplay.kingSquare(pieces, chessDisplay.sideToMove(fen)) : ""
    }

    function explorationPrompt() {
        if (gameReviewScreen.exploreStatusCode === "checkmate") return "Checkmate — candidate line ends."
        if (gameReviewScreen.exploreStatusCode === "stalemate") return "Stalemate — candidate line ends."
        if (gameReviewScreen.exploreStatusCode === "insufficient_material") {
            return "Draw by insufficient material."
        }
        if (gameReviewScreen.exploreStatusCode === "check") return "Check — choose a legal reply."
        return "Tap or drag to explore."
    }

    function promotionOptionsFor(from, to) {
        var out = []
        for (var i = 0; i < gameReviewScreen.exploreLegalMoves.length; i++) {
            var move = gameReviewScreen.exploreLegalMoves[i]
            if (move.from === from && move.to === to && move.promotion) out.push(move.promotion)
        }
        return out
    }

    function promotionPieceCode(letter) {
        var piece = gameReviewScreen.pendingPromotion
            ? (gameReviewScreen.currentPieceMap[gameReviewScreen.pendingPromotion.from] || "")
            : ""
        var isWhite = piece.length > 0
            ? piece === piece.toUpperCase()
            : gameReviewScreen.sideToMove() === "white"
        return (isWhite ? "w" : "b") + letter.toUpperCase()
    }

    function requestExplorationMove(from, to) {
        if (gameReviewScreen.pendingAnalysisRequestId !== 0) return false
        if (gameReviewScreen.destinationsFrom(from).indexOf(to) === -1) return false
        var promotions = gameReviewScreen.promotionOptionsFor(from, to)
        if (promotions.length > 0) {
            gameReviewScreen.pendingPromotion = {from: from, to: to, options: promotions}
        } else {
            gameReviewScreen.submitExplorationMove(from, to, null)
        }
        gameReviewScreen.selectedSquare = ""
        return true
    }

    function onExplorationGesture(from, to) {
        if (!gameReviewScreen.exploreMode || from.length === 0 || to.length === 0) return
        if (gameReviewScreen.pendingAnalysisRequestId !== 0) return
        if (from !== to && gameReviewScreen.requestExplorationMove(from, to)) return
        if (gameReviewScreen.selectedSquare.length > 0) {
            if (gameReviewScreen.selectedSquare === to) {
                gameReviewScreen.selectedSquare = ""
                return
            }
            if (gameReviewScreen.requestExplorationMove(gameReviewScreen.selectedSquare, to)) return
        }
        gameReviewScreen.selectedSquare = gameReviewScreen.isMovablePiece(
            gameReviewScreen.currentPieceMap[to] || ""
        ) ? to : ""
    }

    function rebaseExploration(openingMove) {
        if (!gameReviewScreen.exploreMode || gameReviewScreen.fens.length === 0) return
        gameReviewScreen.showVariations = false
        gameReviewScreen.exploreRootFen = gameReviewScreen.fens[gameReviewScreen.currentIndex]
        gameReviewScreen.selectVariationNode(null, openingMove)
    }

    function applyVariationLine(nodeIndex) {
        var line = VariationTree.line(activeVariation, nodeIndex, exploreRootFen)
        activeVariationNode = nodeIndex
        variationFens = line.fens
        variationMoves = line.moves
        exploreFen = line.fens[line.fens.length - 1]
    }

    function selectVariationNode(nodeIndex, openingMove) {
        applyVariationLine(nodeIndex)
        gameReviewScreen.loadExplorationPosition(openingMove)
    }

    function loadSavedVariations() {
        if (variationStoreState === "loading") return
        variationStoreState = "loading"
        backendSender({type: "RequestReviewVariations", review_id: reviewRequestId})
    }

    function saveVariations() {
        if (variationStoreState !== "ready" || variationSnapshotFull) return
        if (JSON.stringify(reviewVariations).length > VariationTree.maximumSavedBytes) {
            variationSnapshotFull = true
            variationSaveError = "Saved variations are full for this game."
            return
        }
        pendingVariationSaveId = nextRequestId()
        backendSender({type: "SaveReviewVariations", review_id: reviewRequestId,
                       request_id: pendingVariationSaveId, variations: reviewVariations})
    }

    function loadExplorationPosition(openingMove) {
        gameReviewScreen.openingMoveAfterPosition = openingMove || ""
        gameReviewScreen.exploreLegalMoves = []
        gameReviewScreen.selectedSquare = ""
        gameReviewScreen.pendingPromotion = null
        gameReviewScreen.exploreInCheck = null
        gameReviewScreen.exploreStatusCode = "playing"
        gameReviewScreen.refreshBoard()
        gameReviewScreen.sendAnalysisRequest({type: "RequestAnalysisPosition", fen: gameReviewScreen.exploreFen},
                                              "Loading legal moves...")
    }

    function sendAnalysisRequest(message, status) {
        gameReviewScreen.pendingAnalysisRequestId = gameReviewScreen.nextRequestId()
        gameReviewScreen.exploreStatus = status
        message.request_id = gameReviewScreen.pendingAnalysisRequestId
        gameReviewScreen.backendSender(message)
    }

    function submitExplorationMove(from, to, promotion) {
        gameReviewScreen.sendAnalysisRequest({type: "MakeAnalysisMove", fen: gameReviewScreen.exploreFen,
                                              from: from, to: to, promotion: promotion}, "Applying move...")
    }

    function beginExploration(openingMove) {
        if (variationStoreState === "loading") return
        gameReviewScreen.exploreMode = true
        gameReviewScreen.rebaseExploration(openingMove)
    }

    function stopExploration() {
        gameReviewScreen.exploreMode = false
        gameReviewScreen.showVariations = false
        gameReviewScreen.activeVariationNode = null
        gameReviewScreen.pendingAnalysisRequestId = 0
        gameReviewScreen.openingMoveAfterPosition = ""
        gameReviewScreen.exploreFen = ""
        gameReviewScreen.exploreLegalMoves = []
        gameReviewScreen.variationFens = []
        gameReviewScreen.variationMoves = []
        gameReviewScreen.selectedSquare = ""
        gameReviewScreen.pendingPromotion = null
        gameReviewScreen.exploreStatus = ""
        gameReviewScreen.exploreInCheck = null
        gameReviewScreen.exploreStatusCode = "playing"
        gameReviewScreen.refreshBoard()
    }

    function undoExplorationMove() {
        if (activeVariationNode !== null) selectVariationNode(activeVariation.nodes[activeVariationNode].parent)
    }

    // `analysis` may be shorter than `moves` or empty.
    function analysisAt(plyIndex) {
        return plyIndex >= 0 && plyIndex < gameReviewScreen.analysis.length ? gameReviewScreen.analysis[plyIndex] : null
    }

    function judgmentColor(judgment) {
        if (judgment === "Blunder") return theme.errorText
        if (judgment === "Mistake") return theme.lossText
        if (judgment === "Inaccuracy") return theme.textMuted
        return theme.text
    }

    // Centipawns (from White's perspective) -> "+0.85"/"-1.20", or "M3"/"-M2"
    // once one side has a forced mate on the board -- same eval-bar convention
    // as Lichess's own analysis board, just as plain text (no bar here).
    function evalLabel(entry) {
        if (!entry) return ""
        if (entry.mate_in !== null && entry.mate_in !== undefined) {
            return (entry.mate_in > 0 ? "M" : "-M") + Math.abs(entry.mate_in)
        }
        if (entry.eval_cp === null || entry.eval_cp === undefined) return ""
        var pawns = entry.eval_cp / 100
        return (pawns > 0 ? "+" : "") + pawns.toFixed(2)
    }

    function currentCloudEvaluation() {
        return gameReviewScreen.cloudEvaluationPhase === "ready"
            ? gameReviewScreen.currentCloudState.evaluation : null
    }

    function formatCloudNodes(knodes) {
        if (knodes >= 1000000) return (knodes / 1000000).toFixed(1) + "B nodes"
        if (knodes >= 1000) return (knodes / 1000).toFixed(1) + "M nodes"
        return knodes.toLocaleString() + "k nodes"
    }

    function cloudEvaluationLabel() {
        if (gameReviewScreen.cloudEvaluationPhase === "pending") {
            return "Cloud evaluation: loading..."
        }
        if (gameReviewScreen.cloudEvaluationPhase === "unavailable") {
            return "No cached cloud evaluation for this position."
        }
        if (gameReviewScreen.cloudEvaluationPhase === "failed") {
            return "Cloud evaluation failed: " + gameReviewScreen.currentCloudState.message
        }
        var evaluation = gameReviewScreen.currentCloudEvaluation()
        if (!evaluation) return ""
        return "Cloud " + gameReviewScreen.evalLabel(evaluation) +
            " · depth " + evaluation.depth +
            " · " + gameReviewScreen.formatCloudNodes(evaluation.knodes)
    }

    function requestCloudEvaluation() {
        if (!gameReviewScreen.canRequestCloudEvaluation) return
        var fen = gameReviewScreen.cloudFen
        var requestId = gameReviewScreen.nextRequestId()
        gameReviewScreen.setCloudState(fen, {phase: "pending", requestId: requestId})
        gameReviewScreen.backendSender({type: "RequestCloudEvaluation", fen: fen, request_id: requestId,
                                       review_id: gameReviewScreen.reviewRequestId || null})
    }

    function setCloudState(fen, state) {
        var states = Object.assign({}, gameReviewScreen.cloudEvaluationByFen)
        states[fen] = state
        gameReviewScreen.cloudEvaluationByFen = states
    }

    function handleCloudReply(msg) {
        var state = gameReviewScreen.cloudEvaluationByFen[msg.requested_fen]
        if (!state || state.phase !== "pending" || state.requestId !== msg.request_id) return
        if (msg.type === "CloudEvaluation") {
            gameReviewScreen.setCloudState(msg.requested_fen, {phase: "ready", evaluation: msg.evaluation})
        } else if (msg.type === "CloudEvaluationUnavailable") {
            gameReviewScreen.setCloudState(msg.requested_fen, {phase: "unavailable"})
        } else {
            gameReviewScreen.setCloudState(msg.requested_fen, {phase: "failed", message: msg.message || "unknown error"})
        }
    }

    function requestOpeningStatistics() {
        var fen = currentFen()
        if (!fen || !reviewRequestId || openingExplorerCoolingDown ||
                (currentOpeningLookup && currentOpeningLookup.phase !== "failed")) return
        var cache = Object.assign({}, openingLookups)
        if (pendingOpeningLookup) delete cache[pendingOpeningLookup.key]
        var requestId = nextRequestId()
        pendingOpeningLookup = {key: openingLookupKey, requestId: requestId, database: openingDatabase, fen: fen}
        cache[openingLookupKey] = {phase: "pending"}
        openingLookups = cache
        // The path identifies transposed openings. FEN alone can omit their name,
        // while game ID alone cannot describe a position in a candidate line.
        var played = moves.slice(0, currentIndex)
        if (exploreMode) played = played.concat(variationMoves)
        backendSender({type: "RequestOpeningExplorer", request_id: requestId, review_id: reviewRequestId,
                       database: openingDatabase, fen: fen, root_fen: fens[0], played_san: played})
    }

    function handleOpeningReply(msg) {
        var pending = pendingOpeningLookup
        if (!pending || msg.review_id !== reviewRequestId || msg.request_id !== pending.requestId ||
                msg.database !== pending.database || msg.fen !== pending.fen) return
        pendingOpeningLookup = null
        var cache = Object.assign({}, openingLookups)
        if (msg.type === "OpeningExplorer") cache[pending.key] = {phase: "ready", data: msg.data}
        else cache[pending.key] = {phase: "failed", message: msg.message || "Could not load opening statistics."}
        openingLookups = cache
    }

    function submitOpeningMove(uci) {
        submitExplorationMove(uci.slice(0, 2), uci.slice(2, 4), uci[4] || null)
    }

    function tryOpeningMove(uci) {
        if (!canTryOpeningMove || !currentOpeningLookup || currentOpeningLookup.phase !== "ready" ||
                !currentOpeningLookup.data.moves.some(function(move) { return move.uci === uci })) return
        showOpeningExplorer = false
        if (exploreMode) submitOpeningMove(uci)
        else beginExploration(uci)
    }

    function moveRows() {
        return chessDisplay.moveRows(
            gameReviewScreen.moves,
            gameReviewScreen.clockMs,
            gameReviewScreen.analysis,
            gameReviewScreen.fens[0]
        )
    }

    function resultColor(result) {
        if (result === "win") return theme.winText
        if (result === "loss") return theme.lossText
        return theme.drawText
    }

    function gameDetailsLabel() {
        if (!gameReviewScreen.game) return ""
        var parts = []
        if (gameReviewScreen.game.rated === true) parts.push("Rated")
        else if (gameReviewScreen.game.rated === false) parts.push("Casual")
        if (gameReviewScreen.game.speed) {
            parts.push(chessDisplay.speedLabel(gameReviewScreen.game.speed))
        }
        var variant = chessDisplay.variantLabel(gameReviewScreen.game.variant)
        if (variant) parts.push(variant)
        if (gameReviewScreen.game.termination) {
            parts.push(chessDisplay.terminationLabel(gameReviewScreen.game.termination))
        }
        if (gameReviewScreen.game.opening_name) parts.push(gameReviewScreen.game.opening_name)
        if (gameReviewScreen.game.created_at_ms) {
            parts.push(new Date(gameReviewScreen.game.created_at_ms).toLocaleDateString())
        }
        return parts.join(" · ")
    }

    function goFirst() { gameReviewScreen.currentIndex = 0 }
    function goPrev() { gameReviewScreen.currentIndex = Math.max(0, gameReviewScreen.currentIndex - 1) }
    function goNext() { gameReviewScreen.currentIndex = Math.min(gameReviewScreen.fens.length - 1, gameReviewScreen.currentIndex + 1) }
    function goLast() { gameReviewScreen.currentIndex = gameReviewScreen.fens.length - 1 }

    Column {
        id: boardArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        spacing: theme.spacingXs

        Row {
            spacing: theme.spacingSmall
            visible: gameReviewScreen.game !== null
            Text {
                text: gameReviewScreen.game ? chessDisplay.resultLabel(gameReviewScreen.game.result) : ""
                font.pixelSize: theme.fontLabel
                font.bold: true
                color: gameReviewScreen.game ? gameReviewScreen.resultColor(gameReviewScreen.game.result) : theme.text
            }
            // Your own rating change from this one game (rated games only).
            Text {
                visible: gameReviewScreen.game !== null && gameReviewScreen.game.rating_diff !== null && gameReviewScreen.game.rating_diff !== undefined
                text: gameReviewScreen.game && gameReviewScreen.game.rating_diff > 0
                    ? ("+" + gameReviewScreen.game.rating_diff)
                    : ("" + (gameReviewScreen.game ? gameReviewScreen.game.rating_diff : ""))
                font.pixelSize: theme.fontLabel
                color: gameReviewScreen.game && gameReviewScreen.game.rating_diff > 0 ? theme.winText : theme.lossText
            }
            Text {
                text: gameReviewScreen.game
                    ? chessDisplay.opponentLabel(gameReviewScreen.game) +
                      (gameReviewScreen.game.opponent_rating ? " (" + gameReviewScreen.game.opponent_rating + ")" : "")
                    : ""
                font.pixelSize: theme.fontLabel
                color: theme.text
            }
        }

        Text {
            visible: gameReviewScreen.game !== null
            text: gameReviewScreen.gameDetailsLabel()
            font.pixelSize: theme.fontSmall
            wrapMode: Text.WordWrap
            width: parent.width
            color: theme.textMuted
        }

        // Whole-game "report card" from Lichess's own computer analysis --
        // only present once this specific game has actually been through it
        // (most never are), same your_analysis field GameHistoryScreen's row
        // now also reads.
        Text {
            visible: gameReviewScreen.game !== null &&
                gameReviewScreen.game.your_analysis !== null &&
                gameReviewScreen.game.your_analysis !== undefined
            text: gameReviewScreen.game && gameReviewScreen.game.your_analysis
                ? "Your accuracy: " +
                  (gameReviewScreen.game.your_analysis.accuracy !== null && gameReviewScreen.game.your_analysis.accuracy !== undefined
                      ? gameReviewScreen.game.your_analysis.accuracy + "%"
                      : "n/a") +
                  " · " + gameReviewScreen.game.your_analysis.inaccuracies + " inaccuracies, " +
                  gameReviewScreen.game.your_analysis.mistakes + " mistakes, " +
                  gameReviewScreen.game.your_analysis.blunders + " blunders"
                : ""
            font.pixelSize: theme.fontSmall
            wrapMode: Text.WordWrap
            width: parent.width
            color: theme.textMuted
        }

        Row {
            spacing: theme.spacingSmall
            Text {
                objectName: "reviewPositionStatus"
                text: gameReviewScreen.exploreMode
                    ? (gameReviewScreen.variationStorageError
                       ? gameReviewScreen.variationStorageError + "\n" + gameReviewScreen.exploreStatus
                       : gameReviewScreen.exploreStatus)
                    : (gameReviewScreen.currentIndex === 0
                        ? "Starting position"
                        : "Move " + gameReviewScreen.currentIndex + " of " +
                          Math.max(0, gameReviewScreen.fens.length - 1))
                font.pixelSize: theme.fontLabel
                font.bold: gameReviewScreen.exploreMode
                width: gameReviewScreen.exploreMode ? boardArea.width : implicitWidth
                textFormat: Text.PlainText
                wrapMode: gameReviewScreen.exploreMode ? Text.Wrap : Text.NoWrap
                maximumLineCount: gameReviewScreen.exploreMode ? 2 : 1
                elide: Text.ElideRight
                color: theme.text
            }
            Text {
                visible: !gameReviewScreen.exploreMode
                text: gameReviewScreen.evalLabel(gameReviewScreen.displayedArchiveAnalysis)
                font.pixelSize: theme.fontLabel
                font.bold: true
                color: theme.textMuted
            }
        }

        Text {
            objectName: "reviewMoveJudgment"
            visible: text.length > 0
            text: gameReviewScreen.displayedArchiveAnalysis
                ? gameReviewScreen.displayedArchiveAnalysis.judgment_comment || "" : ""
            font.pixelSize: theme.fontSmall
            wrapMode: Text.WordWrap
            width: parent.width
            color: gameReviewScreen.judgmentColor(
                gameReviewScreen.displayedArchiveAnalysis
                    ? gameReviewScreen.displayedArchiveAnalysis.judgment : null
            )
        }

        Text {
            visible: gameReviewScreen.cloudEvaluationLabel().length > 0
            text: gameReviewScreen.cloudEvaluationLabel()
            font.pixelSize: theme.fontSmall
            font.bold: gameReviewScreen.currentCloudEvaluation() !== null
            width: parent.width
            elide: Text.ElideRight
            color: gameReviewScreen.cloudEvaluationPhase === "failed"
                ? theme.errorText
                : theme.textMuted
        }

        AppButton {
            objectName: "cloudBestLineButton"
            visible: gameReviewScreen.cloudBestMoves.length > 0
            compact: true
            text: "Cloud best line"
            onClicked: gameReviewScreen.showCloudLine = true
        }

        Item {
            id: boardSection
            width: parent.width
            height: grid.height
            // Reserve a complete row before sizing the board. Hiding metadata
            // loses context, and a fixed smaller board wastes room on quiet screens.
            readonly property real availableHeight: backButton.y - boardArea.y - y -
                theme.touchTarget - boardArea.spacing -
                (fileLabels.visible ? fileLabels.height + boardArea.spacing : 0) -
                moveList.anchors.topMargin - moveList.anchors.bottomMargin - moveList.minimumUsableHeight

            Column {
                id: rankLabels
                objectName: "boardRankLabels"
                width: gameReviewScreen.coordinateGutter
                anchors.right: boardSurface.left
                anchors.rightMargin: theme.spacingXs
                visible: gameReviewScreen.showCoordinates
                Repeater {
                    model: 8
                    Text {
                        required property int index
                        width: rankLabels.width
                        height: grid.height / 8
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: gameReviewScreen.fr.ranks[index]
                        font.pixelSize: theme.fontSmall
                        color: theme.text
                    }
                }
            }

            Item {
                id: boardSurface
                x: chessDisplay.boardLeft(parent.width, width, rankLabels.width + theme.spacingXs)
                width: grid.width
                height: grid.height

            Grid {
                id: grid
                columns: 8
                rows: 8
                width: Math.max(0, Math.min(
                    boardArea.width - rankLabels.width - theme.spacingXs,
                    gameReviewScreen.height * 0.42,
                    boardSection.availableHeight
                ))
                height: width

                Repeater {
                    model: 64
                    BoardSquare {
                        required property int index
                        objectName: "boardSquare-" + squareName
                        width: grid.width / 8
                        height: grid.height / 8
                        property int fileIdx: index % 8
                        property int rankIdx: Math.floor(index / 8)
                        squareName: gameReviewScreen.fr.files[fileIdx] + gameReviewScreen.fr.ranks[rankIdx]
                        isLight: (fileIdx + rankIdx) % 2 === 0
                        darkMode: gameReviewScreen.darkMode
                        lightSquareColor: boardStyle.lightSquare
                        darkSquareColor: boardStyle.darkSquare
                        checkSquareColor: boardStyle.checkSquare
                        highlightSquareColor: boardStyle.highlightSquare
                        lastMoveSquareColor: boardStyle.lastMoveSquare
                        premoveSquareColor: boardStyle.premoveSquare
                        inkColor: boardStyle.ink
                        pieceSet: gameReviewScreen.pieceSet
                        pieceCode: gameReviewScreen.pieceCodeFor(gameReviewScreen.currentPieceMap[squareName] || "")
                        isHighlighted: isSelected || isLegalDestination
                        isSelected: gameReviewScreen.exploreMode &&
                            gameReviewScreen.selectedSquare === squareName
                        isLegalDestination: gameReviewScreen.exploreMode &&
                            !gameReviewScreen.minimalHighlights &&
                            gameReviewScreen.selectedDestinationLookup[squareName] === true
                        isLastMove: gameReviewScreen.highlightLastMove &&
                            gameReviewScreen.lastMoveSquareLookup[squareName] === true
                        isCheckSquare: squareName === gameReviewScreen.checkedSquare
                        flashRefresh: gameReviewScreen.flashSquareLookup[squareName] === true
                    }
                }
            }

            MouseArea {
                anchors.fill: grid
                enabled: gameReviewScreen.exploreMode
                property string pressSquare: ""
                property real pressX: 0
                property real pressY: 0
                preventStealing: true
                onPressed: (mouse) => {
                    pressSquare = gameReviewScreen.squareAtBoardPoint(mouse.x, mouse.y)
                    pressX = mouse.x
                    pressY = mouse.y
                }
                onReleased: (mouse) => {
                    var releaseSquare = gameReviewScreen.squareAtBoardPoint(mouse.x, mouse.y)
                    var dx = mouse.x - pressX
                    var dy = mouse.y - pressY
                    if (dx * dx + dy * dy < theme.boardDragThreshold * theme.boardDragThreshold) {
                        releaseSquare = pressSquare
                    }
                    gameReviewScreen.onExplorationGesture(pressSquare, releaseSquare)
                    pressSquare = ""
                }
                onCanceled: pressSquare = ""
            }

            }
        }

        Row {
            id: fileLabels
            objectName: "boardFileLabels"
            x: boardSurface.x
            width: grid.width
            visible: gameReviewScreen.showCoordinates
            Repeater {
                model: 8
                Text {
                    required property int index
                    width: grid.width / 8
                    horizontalAlignment: Text.AlignHCenter
                    text: gameReviewScreen.fr.files[index]
                    font.pixelSize: theme.fontSmall
                    color: theme.text
                }
            }
        }

        Row {
            width: parent.width
            spacing: theme.spacingXs
            visible: !gameReviewScreen.exploreMode

            BoardToolButton {
                width: (parent.width - parent.spacing * 3) / 4
                text: "Menu"
                onClicked: gameReviewScreen.showReviewOptions = true
            }
            BoardToolButton {
                objectName: "beginExplorationButton"
                width: (parent.width - parent.spacing * 3) / 4
                text: gameReviewScreen.variationStoreState === "loading" ? "Loading…" : "Explore"
                enabled: gameReviewScreen.variationStoreState !== "loading"
                onClicked: gameReviewScreen.beginExploration()
            }
            BoardToolButton {
                width: (parent.width - parent.spacing * 3) / 4
                text: "‹"
                enabled: gameReviewScreen.currentIndex > 0
                onClicked: gameReviewScreen.goPrev()
            }
            BoardToolButton {
                width: (parent.width - parent.spacing * 3) / 4
                text: "›"
                enabled: gameReviewScreen.currentIndex < gameReviewScreen.fens.length - 1
                onClicked: gameReviewScreen.goNext()
            }
        }

        Row {
            width: parent.width
            spacing: theme.spacingXs
            visible: gameReviewScreen.exploreMode

            BoardToolButton {
                width: (parent.width - parent.spacing * 3) / 4
                text: "Menu"
                onClicked: gameReviewScreen.showReviewOptions = true
            }
            BoardToolButton {
                width: (parent.width - parent.spacing * 3) / 4
                text: "Exit"
                highlighted: true
                onClicked: gameReviewScreen.stopExploration()
            }
            BoardToolButton {
                objectName: "previousVariationPositionButton"
                width: (parent.width - parent.spacing * 3) / 4
                text: "Previous"
                enabled: gameReviewScreen.variationMoves.length > 0
                onClicked: gameReviewScreen.undoExplorationMove()
            }
            BoardToolButton {
                objectName: "showVariationsButton"
                width: (parent.width - parent.spacing * 3) / 4
                text: "Lines"
                enabled: gameReviewScreen.activeVariation.nodes.length > 0 ||
                         gameReviewScreen.variationLoadError.length > 0
                onClicked: gameReviewScreen.showVariations = true
            }
        }

    }

    // The paged dialog keeps the board fixed. Inline lines displace notation,
    // while a separate screen loses the position being explored.
    VariationDialog {
        anchors.fill: parent
        visible: gameReviewScreen.showVariations
        darkMode: gameReviewScreen.darkMode
        lines: visible ? VariationTree.tips(gameReviewScreen.activeVariation) : []
        currentNode: gameReviewScreen.activeVariationNode
        storageError: gameReviewScreen.variationStorageError
        showRetryLoad: gameReviewScreen.variationLoadError.length > 0
        loadingSaved: gameReviewScreen.variationStoreState === "loading"
        canRetrySave: gameReviewScreen.variationSaveError.length > 0 &&
                      !gameReviewScreen.variationSnapshotFull &&
                      gameReviewScreen.pendingVariationSaveId === 0
        onSelected: (nodeIndex) => {
            gameReviewScreen.showVariations = false
            gameReviewScreen.selectVariationNode(nodeIndex)
        }
        onRetryLoad: gameReviewScreen.loadSavedVariations()
        onRetrySave: gameReviewScreen.saveVariations()
        onDismissed: gameReviewScreen.showVariations = false
    }

    AppDialog {
        anchors.fill: parent
        visible: gameReviewScreen.showReviewOptions
        darkMode: gameReviewScreen.darkMode
        title: "Board options"
        onDismissed: gameReviewScreen.showReviewOptions = false

                AppButton {
                    width: parent.width
                    text: "First position"
                    visible: !gameReviewScreen.exploreMode
                    enabled: gameReviewScreen.currentIndex > 0
                    onClicked: {
                        gameReviewScreen.goFirst()
                        gameReviewScreen.showReviewOptions = false
                    }
                }
                AppButton {
                    width: parent.width
                    text: "Last position"
                    visible: !gameReviewScreen.exploreMode
                    enabled: gameReviewScreen.currentIndex < gameReviewScreen.fens.length - 1
                    onClicked: {
                        gameReviewScreen.goLast()
                        gameReviewScreen.showReviewOptions = false
                    }
                }
                AppButton {
                    width: parent.width
                    text: "Flip board"
                    onClicked: {
                        gameReviewScreen.manualFlip = !gameReviewScreen.manualFlip
                        gameReviewScreen.showReviewOptions = false
                    }
                }
                AppButton {
                    objectName: "requestCloudEvaluationButton"
                    width: parent.width
                    text: gameReviewScreen.currentCloudEvaluation() !== null
                        ? "Cloud evaluation loaded"
                        : gameReviewScreen.cloudEvaluationPhase === "unavailable"
                            ? "No cloud evaluation cached"
                            : gameReviewScreen.cloudEvaluationPhase === "pending"
                                ? "Loading cloud evaluation..."
                                : gameReviewScreen.cloudEvaluationCoolingDown
                                    ? "Cloud evaluation paused" : "Cloud evaluation"
                    enabled: gameReviewScreen.canRequestCloudEvaluation
                    onClicked: {
                        gameReviewScreen.requestCloudEvaluation()
                        gameReviewScreen.showReviewOptions = false
                    }
                }
                AppButton {
                    objectName: "openOpeningExplorerButton"
                    width: parent.width
                    text: "Opening explorer"
                    enabled: gameReviewScreen.reviewRequestId > 0 && gameReviewScreen.currentFen().length > 0
                    onClicked: {
                        gameReviewScreen.showReviewOptions = false
                        gameReviewScreen.showOpeningExplorer = true
                        gameReviewScreen.requestOpeningStatistics()
                    }
                }
                AppButton {
                    objectName: "openPgnExportButton"
                    width: parent.width
                    visible: gameReviewScreen.pgnGameId.length > 0 && !!gameReviewScreen.openPgnExport
                    text: "Export PGN"
                    onClicked: {
                        gameReviewScreen.showReviewOptions = false
                        gameReviewScreen.openPgnExport(gameReviewScreen.pgnGameId, true)
                    }
                }
                AppButton {
                    width: parent.width
                    text: "Close"
                    onClicked: gameReviewScreen.showReviewOptions = false
                }
    }

    OpeningExplorerDialog {
        anchors.fill: parent
        visible: gameReviewScreen.showOpeningExplorer
        darkMode: gameReviewScreen.darkMode
        database: gameReviewScreen.openingDatabase
        lookup: gameReviewScreen.currentOpeningLookup
        coolingDown: gameReviewScreen.openingExplorerCoolingDown
        canTryMove: gameReviewScreen.canTryOpeningMove
        onDatabaseSelected: (database) => {
            gameReviewScreen.openingDatabase = database
            gameReviewScreen.requestOpeningStatistics()
        }
        onLookupRequested: gameReviewScreen.requestOpeningStatistics()
        onMoveSelected: (uci) => gameReviewScreen.tryOpeningMove(uci)
        onDismissed: gameReviewScreen.showOpeningExplorer = false
    }

    AppButton {
        id: backButton
        objectName: "reviewBackButton"
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: theme.pageSideMargin
        width: Math.min(parent.width - theme.pageSideMargin * 2,
                        Math.max(theme.textFieldWidthMedium, naturalWidth))
        compact: true
        text: "Back to Game History"
        onClicked: gameReviewScreen.returnToGameHistory()
    }

    EinkPagedFlickable {
        id: moveList
        objectName: "reviewMoveList"
        // Anchored between the board controls and the Back button (same
        // pattern as GameHistoryScreen's own ListView) rather than sized by
        // a fixed height -- a long finished game's move list (80+ plies for
        // a 40-move game) would otherwise overflow a plain Column with no
        // way to reach the Back button at all.
        anchors.top: boardArea.bottom
        anchors.topMargin: theme.spacingSmall
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: backButton.top
        anchors.margins: theme.pageSideMargin
        anchors.bottomMargin: theme.spacingSmall
        contentHeight: moveRowsColumn.height
        readonly property real minimumUsableHeight: Math.min(contentHeight, pageControlsHeight +
            (gameReviewScreen.clockMs.length > 0 ? theme.moveRowWithClockHeight : theme.touchTarget))
        onPageHeightChanged: {
            updateMovePageStops()
            if (moveReveal) moveReveal.restart()
        }

        function updateMovePageStops() {
            if (moveRowsColumn) pageStops = rowPageStops(moveRowsColumn.children)
        }

        function revealCurrentMove() {
            var hasCandidate = candidateRepeater.count > 0
            var index = hasCandidate ? gameReviewScreen.variationMoves.length : gameReviewScreen.currentIndex
            if (index <= 0) {
                if (moveList.contentY !== 0) moveList.moveTo(0)
                return
            }
            var startFen = hasCandidate ? gameReviewScreen.variationStartFen : gameReviewScreen.fens[0]
            var rowIndex = chessDisplay.moveRowIndex(index, startFen)
            var item = (hasCandidate ? candidateRepeater : moveRowRepeater).itemAt(rowIndex)
            if (!item) return
            moveRowsColumn.forceLayout()
            moveList.reveal(item.y, item.height)
        }

        Column {
            id: moveRowsColumn
            width: parent.width
            spacing: 0
            onPositioningComplete: moveList.updateMovePageStops()

            // One pager keeps archived moves reachable. A wrapping header shifts the board,
            // and separate panels need another way to switch between them.
            Text {
                width: parent.width
                height: theme.fontSmall + theme.spacingXs
                verticalAlignment: Text.AlignVCenter
                visible: candidateRepeater.count > 0
                text: "Candidate line"
                font.pixelSize: theme.fontSmall
                font.bold: true
                color: theme.textMuted
            }
            Repeater {
                id: candidateRepeater
                model: gameReviewScreen.candidateRows
                MoveListRow {
                    required property var modelData
                    objectName: "candidateMoveRow"
                    selectionEnabled: false
                    width: parent.width
                    darkMode: gameReviewScreen.darkMode
                    moveNumber: modelData.number
                    whiteMove: modelData.white
                    blackMove: modelData.black
                    currentIndex: gameReviewScreen.variationMoves.length
                }
            }
            Text {
                width: parent.width
                height: theme.fontSmall + theme.spacingXs
                verticalAlignment: Text.AlignVCenter
                visible: candidateRepeater.count > 0 && moveRowRepeater.count > 0
                text: "Game moves"
                font.pixelSize: theme.fontSmall
                font.bold: true
                color: theme.textMuted
            }
            Repeater {
                id: moveRowRepeater
                model: gameReviewScreen.moveRows()
                MoveListRow {
                    required property var modelData
                    objectName: "archiveMoveRow"
                    width: parent.width
                    darkMode: gameReviewScreen.darkMode
                    moveNumber: modelData.number
                    whiteMove: modelData.white
                    blackMove: modelData.black
                    currentIndex: gameReviewScreen.currentIndex
                    onMoveSelected: (fenIndex) => gameReviewScreen.currentIndex = fenIndex
                }
            }
        }
    }

    // A paged dialog keeps long lines off the board. A wrapped header moves
    // the board, and mixing cloud rows into the score sheet pushes game moves back.
    Loader {
        anchors.fill: parent
        active: gameReviewScreen.showCloudLine && gameReviewScreen.cloudBestMoves.length > 0
        z: 100
        sourceComponent: Component {
            AppDialog {
                objectName: "cloudBestLineDialog"
                darkMode: gameReviewScreen.darkMode
                title: "Cloud best line"
                pageByRow: true
                onDismissed: gameReviewScreen.showCloudLine = false

                Repeater {
                    model: chessDisplay.moveRows(gameReviewScreen.cloudBestMoves, [], [],
                                                 gameReviewScreen.cloudFen)
                    MoveListRow {
                        required property var modelData
                        objectName: "cloudMoveRow"
                        selectionEnabled: false
                        width: parent.width
                        darkMode: gameReviewScreen.darkMode
                        moveNumber: modelData.number
                        whiteMove: modelData.white
                        blackMove: modelData.black
                    }
                }

                footer: AppButton {
                    objectName: "closeCloudBestLineButton"
                    darkMode: gameReviewScreen.darkMode
                    compact: true
                    text: "Close"
                    onClicked: gameReviewScreen.showCloudLine = false
                }
            }
        }
    }

    PromotionDialog {
        anchors.fill: parent
        visible: gameReviewScreen.pendingPromotion !== null
        darkMode: gameReviewScreen.darkMode
        pieceSet: gameReviewScreen.pieceSet
        options: gameReviewScreen.pendingPromotion
            ? gameReviewScreen.pendingPromotion.options
            : []
        pieceCodeFor: function(piece) {
            return gameReviewScreen.promotionPieceCode(piece)
        }
        onDismissed: gameReviewScreen.pendingPromotion = null
        onChosen: (piece) => {
            var move = gameReviewScreen.pendingPromotion
            if (move === null) return
            gameReviewScreen.pendingPromotion = null
            gameReviewScreen.submitExplorationMove(move.from, move.to, piece)
        }
    }

    function handleMessage(msg) {
        if (msg.type === "RatingDiff") {
            if (gameReviewScreen.game && gameReviewScreen.game.game_id === msg.game_id) {
                gameReviewScreen.game = Object.assign({}, gameReviewScreen.game,
                    {rating_diff: msg.rating_diff})
            }
        } else if (msg.type === "ReviewVariations" || msg.type === "ReviewVariationsLoadFailed") {
            if (msg.review_id !== reviewRequestId || variationStoreState !== "loading") return
            if (msg.type === "ReviewVariations") {
                var hasUnsavedMoves = reviewVariations.positions.length > 0
                reviewVariations = VariationTree.mergeSaved(reviewVariations, msg.variations)
                variationStoreState = "ready"
                variationLoadError = ""
                if (hasUnsavedMoves) saveVariations()
            } else {
                variationLoadError = msg.message
                variationStoreState = "failed"
            }
        } else if (msg.type === "ReviewVariationsSaved" || msg.type === "ReviewVariationsSaveFailed") {
            if (msg.review_id !== reviewRequestId || msg.request_id !== pendingVariationSaveId) return
            pendingVariationSaveId = 0
            if (!variationSnapshotFull) {
                variationSaveError = msg.type === "ReviewVariationsSaveFailed" ? msg.message : ""
            }
        } else if (msg.type === "AnalysisPosition") {
            if (!gameReviewScreen.exploreMode ||
                    msg.request_id !== gameReviewScreen.pendingAnalysisRequestId ||
                    msg.requested_fen !== gameReviewScreen.exploreFen) return
            gameReviewScreen.pendingAnalysisRequestId = 0
            if (activeVariationNode === null) exploreRootFen = msg.fen
            var normalized = variationFens.slice()
            normalized[normalized.length - 1] = msg.fen
            gameReviewScreen.variationFens = normalized
            gameReviewScreen.exploreFen = msg.fen
            gameReviewScreen.exploreLegalMoves = msg.legal_moves || []
            gameReviewScreen.exploreInCheck = typeof msg.in_check === "boolean" ? msg.in_check : null
            gameReviewScreen.exploreStatusCode = msg.status || "playing"
            gameReviewScreen.exploreStatus = gameReviewScreen.explorationPrompt()
            gameReviewScreen.refreshBoard()
            var openingMove = openingMoveAfterPosition
            openingMoveAfterPosition = ""
            if (openingMove) submitOpeningMove(openingMove)
        } else if (msg.type === "AnalysisMove") {
            if (!gameReviewScreen.exploreMode ||
                    msg.request_id !== gameReviewScreen.pendingAnalysisRequestId ||
                    msg.from_fen !== gameReviewScreen.exploreFen) return
            gameReviewScreen.pendingAnalysisRequestId = 0
            var updated = VariationTree.addMove(reviewVariations, activeVariation, activeVariationNode, msg.san, msg.fen)
            var added = updated.variations !== reviewVariations
            reviewVariations = updated.variations
            applyVariationLine(updated.nodeIndex)
            gameReviewScreen.exploreLegalMoves = msg.legal_moves || []
            gameReviewScreen.exploreInCheck = typeof msg.in_check === "boolean" ? msg.in_check : null
            gameReviewScreen.exploreStatusCode = msg.status || "playing"
            gameReviewScreen.selectedSquare = ""
            gameReviewScreen.exploreStatus = gameReviewScreen.explorationPrompt()
            gameReviewScreen.refreshBoard()
            if (added) saveVariations()
        } else if (msg.type === "CloudEvaluation" || msg.type === "CloudEvaluationUnavailable" ||
                   msg.type === "CloudEvaluationFailed") {
            gameReviewScreen.handleCloudReply(msg)
        } else if (msg.type === "OpeningExplorer" || msg.type === "OpeningExplorerFailed") {
            gameReviewScreen.handleOpeningReply(msg)
        } else if (msg.type === "AnalysisFailed") {
            if (gameReviewScreen.exploreMode && msg.request_id === gameReviewScreen.pendingAnalysisRequestId) {
                gameReviewScreen.pendingAnalysisRequestId = 0
                gameReviewScreen.openingMoveAfterPosition = ""
                gameReviewScreen.exploreStatus = msg.message
            }
        }
    }
}
