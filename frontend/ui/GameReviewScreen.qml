import QtQuick 2.5

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
    property var navigateTo
    property bool darkMode: false
    property string boardTheme: "brown"
    property string pieceSet: "cburnett"

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
    // Index into `fens` currently displayed -- 0 is the start, fens.length-1 is
    // the final position. Deliberately independent of `moves`' own indexing
    // (off by one from it) rather than tracking a "current ply" separately.
    property int currentIndex: 0
    property var flashSquares: []
    property string lastRenderedFen: ""
    property var lastRenderedHighlights: []
    onFensChanged: {
        gameReviewScreen.lastRenderedFen = gameReviewScreen.currentFen()
        gameReviewScreen.lastRenderedHighlights = []
    }
    onCurrentIndexChanged: {
        var nextFen = gameReviewScreen.currentFen()
        var refreshSquares = gameReviewScreen.changedSquaresBetweenFens(
            gameReviewScreen.lastRenderedFen,
            nextFen
        )
        var nextHighlights = gameReviewScreen.currentIndex > 0
            ? gameReviewScreen.changedSquaresBetweenFens(
                gameReviewScreen.fens[gameReviewScreen.currentIndex - 1],
                nextFen
            )
            : []
        gameReviewScreen.appendUniqueSquares(refreshSquares, gameReviewScreen.lastRenderedHighlights)
        gameReviewScreen.appendUniqueSquares(refreshSquares, nextHighlights)
        gameReviewScreen.flashSquares = refreshSquares
        gameReviewScreen.lastRenderedFen = nextFen
        gameReviewScreen.lastRenderedHighlights = nextHighlights
        boardFlashTimer.restart()
        Qt.callLater(function() { moveList.revealCurrentMove() })
        if (gameReviewScreen.exploreMode) gameReviewScreen.rebaseExploration()
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
    property string exploreFen: ""
    property var exploreLegalMoves: []
    property var variationFens: []
    property var variationMoves: []
    property string selectedSquare: ""
    property var pendingPromotion: null
    property string exploreStatus: ""
    property bool exploreInCheck: false
    property string exploreStatusCode: "playing"
    property var cloudEvaluations: ({})
    property var cloudEvaluationUnavailable: ({})
    property string cloudEvaluationPendingFen: ""
    property string cloudEvaluationErrorFen: ""
    property string cloudEvaluationError: ""
    readonly property int coordinateGutter: 52

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

    // Same minimal FEN board decode as BoardScreen.buildPieceMap -- computed
    // once per fen (here: at most twice per redraw, for the current and
    // previous positions) and indexed by every square lookup below, rather
    // than each of up to 128 pieceAt() calls (64 squares x 2 fens in
    // lastMoveSquares) re-walking the whole placement field itself.
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

    function changedSquaresBetweenFens(previousFen, currentFen) {
        if (previousFen === "" || currentFen === "") return []
        var previous = gameReviewScreen.buildPieceMap(previousFen)
        var current = gameReviewScreen.buildPieceMap(currentFen)
        var files = ["a","b","c","d","e","f","g","h"]
        var ranks = ["1","2","3","4","5","6","7","8"]
        var changed = []
        for (var r = 0; r < ranks.length; r++) {
            for (var f = 0; f < files.length; f++) {
                var squareName = files[f] + ranks[r]
                if ((previous[squareName] || "") !== (current[squareName] || "")) changed.push(squareName)
            }
        }
        return changed
    }

    function appendUniqueSquares(target, additions) {
        for (var i = 0; i < additions.length; i++) {
            if (target.indexOf(additions[i]) === -1) target.push(additions[i])
        }
    }

    property var currentPieceMap: gameReviewScreen.buildPieceMap(gameReviewScreen.currentFen())
    property var previousPieceMap: gameReviewScreen.buildPieceMap(gameReviewScreen.previousFen())

    function previousFen() {
        if (gameReviewScreen.exploreMode && gameReviewScreen.variationFens.length > 1) {
            return gameReviewScreen.variationFens[gameReviewScreen.variationFens.length - 2]
        }
        return gameReviewScreen.currentIndex > 0
            ? gameReviewScreen.fens[gameReviewScreen.currentIndex - 1]
            : ""
    }

    // Kept parameterized on `fen` (not hardcoded to currentFen()) so this
    // stays a general-purpose lookup, but the two fens actually in play here
    // (current and previous) go through the cached maps above instead of
    // rebuilding one from scratch on every call.
    function pieceAt(fen, squareName) {
        if (fen === gameReviewScreen.currentFen()) return gameReviewScreen.currentPieceMap[squareName] || ""
        if (fen === gameReviewScreen.previousFen()) {
            return gameReviewScreen.previousPieceMap[squareName] || ""
        }
        return gameReviewScreen.buildPieceMap(fen)[squareName] || ""
    }

    function pieceCodeFor(pieceChar) {
        if (pieceChar === "") return ""
        var isWhite = pieceChar === pieceChar.toUpperCase()
        return (isWhite ? "w" : "b") + pieceChar.toUpperCase()
    }

    // Every square whose piece differs from the previous position -- a plain
    // origin/destination move shows exactly two, castling four, en passant
    // three. There's no separate from/to field to key off (GameMoves only
    // carries SAN + the FEN snapshots), so this diff is what stands in for
    // "last move" highlighting here. Reads the cached maps directly rather
    // than through pieceAt(), since it already knows exactly which two fens
    // it wants.
    function lastMoveSquares() {
        if (gameReviewScreen.previousFen().length === 0) return []
        var files = ["a","b","c","d","e","f","g","h"]
        var ranks = ["1","2","3","4","5","6","7","8"]
        var out = []
        for (var r = 0; r < ranks.length; r++) {
            for (var f = 0; f < files.length; f++) {
                var sq = files[f] + ranks[r]
                if (gameReviewScreen.previousPieceMap[sq] !== gameReviewScreen.currentPieceMap[sq]) out.push(sq)
            }
        }
        return out
    }

    // Cached once per redraw rather than recomputed by each of the 64 squares'
    // own bindings -- same reasoning as BoardScreen's selectedDestinations.
    property var lastMoveSquaresCached: gameReviewScreen.lastMoveSquares()
    property var lastMoveSquareLookup: gameReviewScreen.squareLookup(
        gameReviewScreen.lastMoveSquaresCached)
    property var flashSquareLookup: gameReviewScreen.squareLookup(
        gameReviewScreen.flashSquares)
    // filesRanks() itself is cheap, but it's read by all 64 squares plus 16
    // rank/file labels every redraw, each call allocating two fresh arrays --
    // same "compute once, index many" reasoning as the piece maps above.
    property var fr: gameReviewScreen.filesRanks()

    function sideToMove() {
        var fields = gameReviewScreen.currentFen().split(" ")
        return fields.length > 1 && fields[1] === "b" ? "black" : "white"
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
    property string checkedSquare: gameReviewScreen.explorationCheckedKingSquare()

    function squareLookup(squares) {
        var lookup = {}
        for (var i = 0; i < squares.length; i++) lookup[squares[i]] = true
        return lookup
    }

    function explorationCheckedKingSquare() {
        if (!gameReviewScreen.exploreMode || !gameReviewScreen.exploreInCheck) return ""
        var king = gameReviewScreen.sideToMove() === "white" ? "K" : "k"
        for (var square in gameReviewScreen.currentPieceMap) {
            if (gameReviewScreen.currentPieceMap[square] === king) return square
        }
        return ""
    }

    function explorationPrompt() {
        if (gameReviewScreen.exploreStatusCode === "checkmate") return "Checkmate — candidate line ends."
        if (gameReviewScreen.exploreStatusCode === "stalemate") return "Stalemate — candidate line ends."
        if (gameReviewScreen.exploreStatusCode === "insufficient_material") {
            return "Draw by insufficient material."
        }
        if (gameReviewScreen.exploreStatusCode === "check") return "Check — choose a legal reply."
        return "Tap or drag a piece to explore a candidate line."
    }

    function explorationHeader() {
        if (gameReviewScreen.variationMoves.length === 0) return gameReviewScreen.exploreStatus
        var label = "Candidate: " + gameReviewScreen.variationMoves.join(" ")
        if (gameReviewScreen.exploreStatusCode === "checkmate") return label + " — checkmate"
        if (gameReviewScreen.exploreStatusCode === "stalemate") return label + " — stalemate"
        if (gameReviewScreen.exploreStatusCode === "insufficient_material") return label + " — draw"
        if (gameReviewScreen.exploreStatusCode === "check") return label + " — check"
        return label
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
        if (gameReviewScreen.destinationsFrom(from).indexOf(to) === -1) return false
        var promotions = gameReviewScreen.promotionOptionsFor(from, to)
        if (promotions.length > 0) {
            gameReviewScreen.pendingPromotion = {from: from, to: to, options: promotions}
        } else {
            gameReviewScreen.backendSender({
                type: "MakeAnalysisMove",
                fen: gameReviewScreen.exploreFen,
                from: from,
                to: to,
                promotion: null
            })
        }
        gameReviewScreen.selectedSquare = ""
        return true
    }

    function onExplorationGesture(from, to) {
        if (!gameReviewScreen.exploreMode || from.length === 0 || to.length === 0) return
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

    function rebaseExploration() {
        if (!gameReviewScreen.exploreMode || gameReviewScreen.fens.length === 0) return
        var base = gameReviewScreen.fens[gameReviewScreen.currentIndex]
        gameReviewScreen.exploreFen = base
        gameReviewScreen.variationFens = [base]
        gameReviewScreen.variationMoves = []
        gameReviewScreen.exploreLegalMoves = []
        gameReviewScreen.selectedSquare = ""
        gameReviewScreen.pendingPromotion = null
        gameReviewScreen.exploreStatus = "Loading legal moves..."
        gameReviewScreen.exploreInCheck = false
        gameReviewScreen.exploreStatusCode = "playing"
        gameReviewScreen.backendSender({type: "RequestAnalysisPosition", fen: base})
    }

    function beginExploration() {
        gameReviewScreen.exploreMode = true
        gameReviewScreen.rebaseExploration()
    }

    function stopExploration() {
        gameReviewScreen.exploreMode = false
        gameReviewScreen.exploreFen = ""
        gameReviewScreen.exploreLegalMoves = []
        gameReviewScreen.variationFens = []
        gameReviewScreen.variationMoves = []
        gameReviewScreen.selectedSquare = ""
        gameReviewScreen.pendingPromotion = null
        gameReviewScreen.exploreStatus = ""
        gameReviewScreen.exploreInCheck = false
        gameReviewScreen.exploreStatusCode = "playing"
    }

    function undoExplorationMove() {
        if (gameReviewScreen.variationFens.length <= 1) return
        var nextFens = []
        var nextMoves = []
        for (var i = 0; i < gameReviewScreen.variationFens.length - 1; i++) {
            nextFens.push(gameReviewScreen.variationFens[i])
        }
        for (var j = 0; j < gameReviewScreen.variationMoves.length - 1; j++) {
            nextMoves.push(gameReviewScreen.variationMoves[j])
        }
        gameReviewScreen.variationFens = nextFens
        gameReviewScreen.variationMoves = nextMoves
        gameReviewScreen.exploreFen = nextFens[nextFens.length - 1]
        gameReviewScreen.exploreLegalMoves = []
        gameReviewScreen.selectedSquare = ""
        gameReviewScreen.exploreStatus = "Loading legal moves..."
        gameReviewScreen.exploreInCheck = false
        gameReviewScreen.exploreStatusCode = "playing"
        gameReviewScreen.backendSender({
            type: "RequestAnalysisPosition",
            fen: gameReviewScreen.exploreFen
        })
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
        return gameReviewScreen.cloudEvaluations[gameReviewScreen.currentFen()] || null
    }

    function formatCloudNodes(knodes) {
        if (knodes >= 1000000) return (knodes / 1000000).toFixed(1) + "B nodes"
        if (knodes >= 1000) return (knodes / 1000).toFixed(1) + "M nodes"
        return knodes.toLocaleString() + "k nodes"
    }

    function cloudEvaluationLabel() {
        var fen = gameReviewScreen.currentFen()
        if (fen === gameReviewScreen.cloudEvaluationPendingFen) {
            return "Cloud evaluation: loading..."
        }
        if (gameReviewScreen.cloudEvaluationUnavailable[fen]) {
            return "No cached cloud evaluation for this position."
        }
        if (fen === gameReviewScreen.cloudEvaluationErrorFen) {
            return "Cloud evaluation failed: " + gameReviewScreen.cloudEvaluationError
        }
        var evaluation = gameReviewScreen.currentCloudEvaluation()
        if (!evaluation) return ""
        return "Cloud " + gameReviewScreen.evalLabel(evaluation) +
            " · depth " + evaluation.depth +
            " · " + gameReviewScreen.formatCloudNodes(evaluation.knodes)
    }

    function cloudBestLineLabel() {
        var evaluation = gameReviewScreen.currentCloudEvaluation()
        if (!evaluation || !evaluation.best_line || evaluation.best_line.length === 0) return ""
        return "Best line: " + evaluation.best_line.join(" ")
    }

    function requestCloudEvaluation() {
        var fen = gameReviewScreen.currentFen()
        if (fen.length === 0 || fen === gameReviewScreen.cloudEvaluationPendingFen) return
        gameReviewScreen.cloudEvaluationPendingFen = fen
        gameReviewScreen.cloudEvaluationErrorFen = ""
        gameReviewScreen.cloudEvaluationError = ""
        var unavailable = {}
        for (var key in gameReviewScreen.cloudEvaluationUnavailable) {
            if (key !== fen) unavailable[key] = gameReviewScreen.cloudEvaluationUnavailable[key]
        }
        gameReviewScreen.cloudEvaluationUnavailable = unavailable
        gameReviewScreen.backendSender({type: "RequestCloudEvaluation", fen: fen})
    }

    function moveRows() {
        return chessDisplay.moveRows(
            gameReviewScreen.moves,
            gameReviewScreen.clockMs,
            gameReviewScreen.analysis
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
                    ? "vs " + (gameReviewScreen.game.opponent_name || "Opponent") +
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
                text: gameReviewScreen.exploreMode
                    ? gameReviewScreen.explorationHeader()
                    : (gameReviewScreen.currentIndex === 0
                        ? "Starting position"
                        : "Move " + gameReviewScreen.currentIndex + " of " +
                          Math.max(0, gameReviewScreen.fens.length - 1))
                font.pixelSize: theme.fontLabel
                font.bold: gameReviewScreen.exploreMode
                width: gameReviewScreen.exploreMode ? boardArea.width : implicitWidth
                elide: Text.ElideRight
                color: theme.text
            }
            // Engine eval for the position on the board right now -- from
            // analysis[currentIndex - 1], the ply that produced fens[currentIndex]
            // (analysis has no entry for the starting position, same off-by-one
            // as fens/moves themselves). Empty for an unanalyzed game or before
            // any move has been made yet.
            Text {
                visible: !gameReviewScreen.exploreMode
                text: gameReviewScreen.evalLabel(gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1))
                font.pixelSize: theme.fontLabel
                font.bold: true
                color: theme.textMuted
            }
        }

        // The comment for whichever move is currently displayed, when that
        // move was actually flagged -- e.g. "Blunder. Nxg6 was best.", the
        // exact caption Lichess's own analysis board shows.
        Text {
            visible: gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1) !== null &&
                !!gameReviewScreen.analysisAt(
                    gameReviewScreen.currentIndex - 1
                ).judgment_comment
            text: gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1)
                ? (gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1).judgment_comment || "")
                : ""
            font.pixelSize: theme.fontSmall
            wrapMode: Text.WordWrap
            width: parent.width
            color: gameReviewScreen.judgmentColor(
                gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1)
                    ? gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1).judgment
                    : null
            )
        }

        Text {
            visible: gameReviewScreen.cloudEvaluationLabel().length > 0
            text: gameReviewScreen.cloudEvaluationLabel()
            font.pixelSize: theme.fontSmall
            font.bold: gameReviewScreen.currentCloudEvaluation() !== null
            width: parent.width
            elide: Text.ElideRight
            color: gameReviewScreen.cloudEvaluationErrorFen === gameReviewScreen.currentFen()
                ? theme.errorText
                : theme.textMuted
        }

        Text {
            visible: gameReviewScreen.cloudBestLineLabel().length > 0
            text: gameReviewScreen.cloudBestLineLabel()
            font.pixelSize: theme.fontSmall
            width: parent.width
            elide: Text.ElideRight
            color: theme.text
        }

        Row {
            spacing: theme.spacingXs

            Column {
                id: rankLabels
                Repeater {
                    model: 8
                    Text {
                        required property int index
                        width: gameReviewScreen.coordinateGutter
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
                width: grid.width
                height: grid.height

            Grid {
                id: grid
                columns: 8
                rows: 8
                width: Math.min(
                    boardArea.width - rankLabels.width - theme.spacingXs,
                    gameReviewScreen.height * 0.42
                )
                height: width

                Repeater {
                    model: 64
                    BoardSquare {
                        required property int index
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
                        pieceCode: gameReviewScreen.pieceCodeFor(gameReviewScreen.pieceAt(gameReviewScreen.currentFen(), squareName))
                        property bool isDestination:
                            gameReviewScreen.selectedDestinationLookup[squareName] === true
                        isHighlighted: gameReviewScreen.exploreMode &&
                            (gameReviewScreen.selectedSquare === squareName ||
                             isDestination)
                        isSelected: gameReviewScreen.exploreMode &&
                            gameReviewScreen.selectedSquare === squareName
                        isLegalDestination: gameReviewScreen.exploreMode &&
                            isDestination
                        isLastMove: gameReviewScreen.lastMoveSquareLookup[squareName] === true
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
            spacing: theme.spacingXs
            Item { width: gameReviewScreen.coordinateGutter; height: 1 }
            Row {
                width: grid.width
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
                width: (parent.width - parent.spacing * 3) / 4
                text: "Explore"
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
                width: (parent.width - parent.spacing * 3) / 4
                text: "Undo"
                enabled: gameReviewScreen.variationMoves.length > 0
                onClicked: gameReviewScreen.undoExplorationMove()
            }
            BoardToolButton {
                width: (parent.width - parent.spacing * 3) / 4
                text: "Reset"
                enabled: gameReviewScreen.variationMoves.length > 0
                onClicked: gameReviewScreen.rebaseExploration()
            }
        }

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
                    width: parent.width
                    text: gameReviewScreen.currentCloudEvaluation() !== null
                        ? "Cloud evaluation loaded"
                        : gameReviewScreen.cloudEvaluationUnavailable[gameReviewScreen.currentFen()]
                            ? "No cloud evaluation cached"
                            : gameReviewScreen.cloudEvaluationPendingFen === gameReviewScreen.currentFen()
                                ? "Loading cloud evaluation..."
                                : "Cloud evaluation"
                    enabled: gameReviewScreen.currentFen().length > 0 &&
                             gameReviewScreen.cloudEvaluationPendingFen !== gameReviewScreen.currentFen() &&
                             gameReviewScreen.currentCloudEvaluation() === null &&
                             !gameReviewScreen.cloudEvaluationUnavailable[gameReviewScreen.currentFen()]
                    onClicked: {
                        gameReviewScreen.requestCloudEvaluation()
                        gameReviewScreen.showReviewOptions = false
                    }
                }
                AppButton {
                    width: parent.width
                    text: "Close"
                    onClicked: gameReviewScreen.showReviewOptions = false
                }
    }

    AppButton {
        id: backButton
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: theme.pageSideMargin
        width: Math.min(parent.width - theme.pageSideMargin * 2,
                        Math.max(theme.textFieldWidthMedium, naturalWidth))
        compact: true
        text: "Back to Game History"
        onClicked: gameReviewScreen.navigateTo("GameHistoryScreen.qml")
    }

    EinkPagedFlickable {
        id: moveList
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

        function revealCurrentMove() {
            if (gameReviewScreen.currentIndex <= 0) {
                if (moveList.contentY !== 0) moveList.moveTo(0)
                return
            }
            var rowIndex = Math.floor((gameReviewScreen.currentIndex - 1) / 2)
            var item = moveRowRepeater.itemAt(rowIndex)
            if (!item) return
            moveList.reveal(item.y, item.height)
        }

        Column {
            id: moveRowsColumn
            width: parent.width
            spacing: 0
            Repeater {
                id: moveRowRepeater
                model: gameReviewScreen.moveRows()
                MoveListRow {
                    required property var modelData
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
        onChosen: (piece) => {
            var from = gameReviewScreen.pendingPromotion.from
            var to = gameReviewScreen.pendingPromotion.to
            gameReviewScreen.pendingPromotion = null
            gameReviewScreen.backendSender({
                type: "MakeAnalysisMove",
                fen: gameReviewScreen.exploreFen,
                from: from,
                to: to,
                promotion: piece
            })
        }
    }

    function handleMessage(msg) {
        if (msg.type === "AnalysisPosition") {
            if (!gameReviewScreen.exploreMode ||
                    msg.requested_fen !== gameReviewScreen.exploreFen) return
            var normalized = []
            for (var i = 0; i < gameReviewScreen.variationFens.length; i++) {
                normalized.push(i === gameReviewScreen.variationFens.length - 1
                    ? msg.fen
                    : gameReviewScreen.variationFens[i])
            }
            gameReviewScreen.variationFens = normalized
            gameReviewScreen.exploreFen = msg.fen
            gameReviewScreen.exploreLegalMoves = msg.legal_moves || []
            gameReviewScreen.exploreInCheck = msg.in_check || false
            gameReviewScreen.exploreStatusCode = msg.status || "playing"
            gameReviewScreen.exploreStatus = gameReviewScreen.explorationPrompt()
        } else if (msg.type === "AnalysisMove") {
            if (!gameReviewScreen.exploreMode ||
                    msg.from_fen !== gameReviewScreen.exploreFen) return
            var nextFens = []
            var nextMoves = []
            for (var j = 0; j < gameReviewScreen.variationFens.length; j++) {
                nextFens.push(gameReviewScreen.variationFens[j])
            }
            for (var k = 0; k < gameReviewScreen.variationMoves.length; k++) {
                nextMoves.push(gameReviewScreen.variationMoves[k])
            }
            nextFens.push(msg.fen)
            nextMoves.push(msg.san)
            gameReviewScreen.variationFens = nextFens
            gameReviewScreen.variationMoves = nextMoves
            gameReviewScreen.exploreFen = msg.fen
            gameReviewScreen.exploreLegalMoves = msg.legal_moves || []
            gameReviewScreen.exploreInCheck = msg.in_check || false
            gameReviewScreen.exploreStatusCode = msg.status || "playing"
            gameReviewScreen.selectedSquare = ""
            gameReviewScreen.exploreStatus = gameReviewScreen.explorationPrompt()
        } else if (msg.type === "CloudEvaluation") {
            var evaluations = {}
            for (var key in gameReviewScreen.cloudEvaluations) {
                evaluations[key] = gameReviewScreen.cloudEvaluations[key]
            }
            evaluations[msg.requested_fen] = msg.evaluation
            gameReviewScreen.cloudEvaluations = evaluations
            if (gameReviewScreen.cloudEvaluationPendingFen === msg.requested_fen) {
                gameReviewScreen.cloudEvaluationPendingFen = ""
            }
        } else if (msg.type === "CloudEvaluationUnavailable") {
            var unavailable = {}
            for (var unavailableKey in gameReviewScreen.cloudEvaluationUnavailable) {
                unavailable[unavailableKey] = gameReviewScreen.cloudEvaluationUnavailable[unavailableKey]
            }
            unavailable[msg.requested_fen] = true
            gameReviewScreen.cloudEvaluationUnavailable = unavailable
            if (gameReviewScreen.cloudEvaluationPendingFen === msg.requested_fen) {
                gameReviewScreen.cloudEvaluationPendingFen = ""
            }
        } else if (msg.type === "CloudEvaluationFailed") {
            if (gameReviewScreen.cloudEvaluationPendingFen === msg.requested_fen) {
                gameReviewScreen.cloudEvaluationPendingFen = ""
            }
            gameReviewScreen.cloudEvaluationErrorFen = msg.requested_fen
            gameReviewScreen.cloudEvaluationError = msg.message || "unknown error"
        } else if (msg.type === "ErrorMsg" && gameReviewScreen.exploreMode) {
            gameReviewScreen.exploreStatus = msg.message
        }
    }
}
