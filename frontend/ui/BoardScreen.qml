import QtQuick 2.5

Rectangle {
    id: boardScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: boardScreen.darkMode }
    MoveRequestGate {
        id: moveRequestGate
        gameId: boardScreen.gameId
        onSubmitRequested: (message) => boardScreen.backendSender(message)
    }
    property var backendSender
    property var navigateTo
    property var openGameReview: function() {}
    property bool darkMode: false

    property string gameId: ""
    property string fen: ""
    property string liveFen: ""
    property string turn: "white"
    // Pushed from main.qml's root state (TokenVerified's username) -- shown
    // on your own player bar below the board, matching every reference
    // client's "your side is a real labeled player too" treatment.
    property string username: ""
    property int whiteTimeMs: 0
    property int blackTimeMs: 0
    // Fixed for the game's lifetime (see game::session::GameSession) -- null
    // for an untimed/correspondence game, same Option-to-null convention as
    // opponentRating. Needed alongside the live whiteTimeMs/blackTimeMs
    // above to compute isLowTime()'s 1/8-of-total threshold correctly, since
    // the live values alone don't say what the total ever was.
    property var initialClockMs: null
    property var legalMoves: []
    property string selectedSquare: ""
    property string statusText: ""
    property var flashSquares: []
    Timer {
        id: boardFlashTimer
        interval: 90
        onTriggered: boardScreen.flashSquares = []
    }
    // Which color the local account is playing -- flips board orientation below.
    // Every reference client (lichess's own official board package included)
    // treats this as required, not optional; defaults to "white" until the first
    // BoardState arrives, matching the backend's own fallback in an unrecognized-id
    // edge case (see game::session::resolve_your_color).
    property string yourColor: "white"
    // last_move and in_check were already computed and sent by the backend before
    // this change -- last_move was simply never read by this screen.
    property var lastMove: null
    property bool inCheck: false
    property bool drawOfferedByOpponent: false
    property bool takebackOfferedByOpponent: false
    property bool drawOfferedByYou: false
    property bool takebackOfferedByYou: false
    property bool canAbort: false
    property bool canBerserk: false
    property bool canOfferDraw: false
    property bool canOfferTakeback: false
    property bool canGiveTime: false
    property bool canChat: false
    // Set from the backend's OpponentGone message. Lichess's claim-victory
    // endpoint remains authoritative and rejects an early claim.
    property bool opponentGone: false
    property int claimWinInSeconds: 0
    // User-controlled override, independent of yourColor -- XORed with the
    // yourColor-based orientation below, same as every reference client's
    // "flip board" action.
    property bool manualFlip: false
    // {from, to, options: [promotion letters]} while a promotion piece choice is
    // pending, else null. Set instead of immediately sending MakeMove whenever a
    // pawn move has more than one legal promotion option.
    property var pendingPromotion: null
    property string pendingGameAction: ""
    property bool showGameActions: false
    property bool showMoves: false
    property bool showChat: false
    // Set when RatingDiff arrives before GameOver does -- the per-game
    // stream's terminal GameState (driving GameOver) and the account
    // stream's gameFinish (driving RatingDiff) are two independent signals
    // that arrive close together but in no guaranteed order. Appended by the
    // GameOver handler once it runs; cleared immediately after so a second,
    // later game's own GameOver doesn't accidentally re-append a stale value.
    property string pendingRatingDiffText: ""
    // "username: text" lines, player-room only (see backend_app.rs's chat.room
    // == "player" filter) -- oldest first, matching Lichess's own chat panel.
    property var chatMessages: []
    // SAN per move, sent whole by the backend each BoardState (see
    // game::session::GameSession.move_history) -- only re-rendered when it
    // actually changes, same as everything else here.
    property var moveHistory: []
    property var positionHistory: []
    property int historyIndex: -1
    property bool viewingHistory: boardScreen.positionHistory.length > 0 &&
        boardScreen.historyIndex >= 0 &&
        boardScreen.historyIndex < boardScreen.positionHistory.length - 1
    property var capturedByWhite: []
    property var capturedByBlack: []
    // Fixed for the game's lifetime (see game::session::GameSession) -- an AI
    // opponent has no rating, only a name/level, hence the Option on the
    // backend and the "" / null fallback here.
    property string opponentName: ""
    property var opponentRating: null
    property string gameDescription: ""
    property var firstMoveTimeMs: null
    // Pushed from main.qml's root state (see settings.rs / SettingsScreen.qml) --
    // when on, a queen promotion is sent immediately instead of opening the
    // picker popup below. Only skips the popup when "q" is actually one of the
    // legal options; an underpromotion-only edge case (extremely rare, but real)
    // still gets the picker regardless of this setting.
    property bool autoQueenPromotion: false
    // Pushed from main.qml's root state, same pattern as autoQueenPromotion
    // above -- when on, gates every legal move behind an explicit Confirm/
    // Cancel step (see requestMove/pendingMoveConfirmation) instead of
    // sending MakeMove the instant a legal destination is tapped. Confirmed
    // against the official lichess-org/mobile app's own moveToConfirm
    // setting (see docs/superpowers/plans/2026-07-21-ui-strategy-phases-plan.md's
    // Phase 3) -- same off-by-default posture as auto-queen above.
    property bool moveConfirmation: false
    // {from, to, promotion} while a move is pending the user's explicit
    // Confirm/Cancel (only when moveConfirmation is on), else null. Applied
    // as the *last* gate before any network call -- the promotion picker
    // above still resolves first if a promotion is involved, matching the
    // official app's own ordering.
    property var pendingMoveConfirmation: null
    // Pushed from main.qml's root state, same pattern as autoQueenPromotion/
    // moveConfirmation above -- when on, tap-to-select highlights only the
    // selected square itself, skipping the legal-destination fill (up to
    // ~28 squares otherwise) to halve the damaged redraw area per selection.
    // Off by default: full highlighting is the more helpful default, this
    // just trades some of that away for speed once someone wants it.
    property bool minimalHighlights: false
    property bool premovesEnabled: false
    property var pendingPremove: null
    onPremovesEnabledChanged: {
        if (!boardScreen.premovesEnabled) boardScreen.cancelPremove()
    }
    property bool gameOver: false
    readonly property bool canNavigateHome: boardScreen.gameOver
    property string gameResult: ""
    property string gameReason: ""
    property bool annotationMode: false
    property var boardAnnotations: []
    property bool liveClockEnabled: true
    property double lastClockSyncMs: 0
    property int clockPulse: 0
    Timer {
        interval: 1000
        repeat: true
        running: boardScreen.visible &&
            boardScreen.liveClockEnabled &&
            (boardScreen.initialClockMs !== null ||
                boardScreen.firstMoveTimeMs !== null) &&
            !boardScreen.gameOver &&
            boardScreen.fen.length > 0
        onTriggered: boardScreen.clockPulse += 1
    }

    // Single choke point for "a move is fully resolved (including any
    // promotion piece) and ready to send" -- either sends it immediately, or
    // (when moveConfirmation is on) parks it in pendingMoveConfirmation for
    // confirmPendingMove/cancelPendingMove to resolve. Every MakeMove send
    // in this file goes through here rather than calling backendSender
    // directly, so the confirmation gate can't accidentally be bypassed by
    // one call site while another respects it.
    function requestMove(from, to, promotion) {
        if (moveRequestGate.pending !== null) return
        if (boardScreen.moveConfirmation) {
            boardScreen.pendingMoveConfirmation = {from: from, to: to, promotion: promotion}
        } else {
            boardScreen.submitMove(from, to, promotion)
        }
    }

    function submitMove(from, to, promotion) {
        if (!moveRequestGate.submit(from, to, promotion)) return false
        boardScreen.selectedSquare = ""
        return true
    }

    function toggleAnnotation(from, to) {
        if (from.length === 0 || to.length === 0) return
        var next = []
        var removed = false
        for (var i = 0; i < boardScreen.boardAnnotations.length; i++) {
            var annotation = boardScreen.boardAnnotations[i]
            if (annotation.from === from && annotation.to === to) {
                removed = true
            } else {
                next.push(annotation)
            }
        }
        if (!removed) next.push({from: from, to: to})
        boardScreen.boardAnnotations = next
    }

    function clearAnnotations() {
        boardScreen.boardAnnotations = []
    }

    function setAnnotationMode(enabled) {
        boardScreen.annotationMode = enabled
        boardScreen.selectedSquare = ""
        boardScreen.pendingPromotion = null
        boardScreen.pendingMoveConfirmation = null
    }

    function confirmPendingMove() {
        if (boardScreen.pendingMoveConfirmation === null) return
        var move = boardScreen.pendingMoveConfirmation
        boardScreen.pendingMoveConfirmation = null
        boardScreen.submitMove(move.from, move.to, move.promotion)
    }

    function cancelPendingMove() {
        boardScreen.pendingMoveConfirmation = null
        boardScreen.selectedSquare = ""
    }

    // "1. e4 e5  2. Nf3 Nc6  ..." -- pairs white/black plies under one move
    // number, standard chess notation, matching what cli-chess's MoveListModel
    // and every mainstream client show.
    function formattedMoveHistory() {
        var out = []
        for (var i = 0; i < boardScreen.moveHistory.length; i++) {
            if (i % 2 === 0) {
                out.push((i / 2 + 1) + ". " + boardScreen.moveHistory[i])
            } else {
                out[out.length - 1] += " " + boardScreen.moveHistory[i]
            }
        }
        return out.join("  ")
    }

    function moveTokens() {
        var out = []
        for (var i = 0; i < boardScreen.moveHistory.length; i++) {
            out.push({
                label: (i % 2 === 0 ? (i / 2 + 1) + ". " : "") + boardScreen.moveHistory[i],
                fenIndex: i + 1
            })
        }
        return out
    }

    function showHistoryPosition(index) {
        if (boardScreen.positionHistory.length === 0) return
        var bounded = Math.max(0, Math.min(index, boardScreen.positionHistory.length - 1))
        boardScreen.historyIndex = bounded
        boardScreen.fen = boardScreen.positionHistory[bounded]
        boardScreen.selectedSquare = ""
        boardScreen.pendingPromotion = null
        boardScreen.pendingMoveConfirmation = null
        boardScreen.clearAnnotations()
    }

    function returnToLive() {
        if (boardScreen.positionHistory.length === 0) return
        boardScreen.showHistoryPosition(boardScreen.positionHistory.length - 1)
    }

    // Display-order files/ranks, flipped when playing black so the local player's
    // own pieces render at the bottom, matching standard chess-app convention.
    // Written as two plain literals rather than slice().reverse() -- qmllint
    // infers a QVariantList type for these array literals under Qt6's stricter
    // QML type system, which doesn't reliably expose Array.prototype methods.
    function formatClock(ms) {
        var totalSeconds = Math.floor(ms / 1000)
        var minutes = Math.floor(totalSeconds / 60)
        var seconds = totalSeconds % 60
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    }

    // Threshold matches the official lichess-org/mobile app's own low-time
    // warning (confirmed via that project's issue #785, not invented): 1/8
    // of the side's total time control, clamped to [10s, 60s] -- a 3-minute
    // blitz game's "low time" kicks in a lot sooner than a 2-hour classical
    // game's does. Returns false
    // (not low) for an untimed/correspondence game, where totalMs is null.
    function isLowTime(ms, totalMs) {
        if (totalMs === null || totalMs === undefined) return false
        return ms < Math.min(60000, Math.max(10000, totalMs / 8))
    }

    function filesRanks() {
        var showBlackAtBottom = (boardScreen.yourColor === "black") !== boardScreen.manualFlip
        if (showBlackAtBottom) {
            return {files: ["h","g","f","e","d","c","b","a"], ranks: ["1","2","3","4","5","6","7","8"]}
        }
        return {files: ["a","b","c","d","e","f","g","h"], ranks: ["8","7","6","5","4","3","2","1"]}
    }

    function isLastMoveSquare(sq) {
        if (boardScreen.viewingHistory) {
            return boardScreen.historicalLastMoveSquares.indexOf(sq) !== -1
        }
        return boardScreen.lastMove !== null &&
            (sq === boardScreen.lastMove[0] || sq === boardScreen.lastMove[1])
    }

    // Finds the square of whichever king is currently in check (always the side
    // to move's own king -- you can't end your move still in check). Iterates a
    // fixed absolute a1..h8 sweep rather than the display-order filesRanks(), since
    // square *names* don't depend on board orientation, only where they're drawn.
    function checkedKingSquareFor(fen, turn, inCheck) {
        if (!inCheck) return ""
        var map = boardScreen.buildPieceMap(fen)
        var kingChar = turn === "white" ? "K" : "k"
        var files = ["a","b","c","d","e","f","g","h"]
        var ranks = ["1","2","3","4","5","6","7","8"]
        for (var r = 0; r < ranks.length; r++) {
            for (var f = 0; f < files.length; f++) {
                var sq = files[f] + ranks[r]
                if ((map[sq] || "") === kingChar) return sq
            }
        }
        return ""
    }

    function checkedKingSquare() {
        if (boardScreen.viewingHistory) return ""
        return boardScreen.checkedKingSquareFor(boardScreen.fen, boardScreen.turn, boardScreen.inCheck)
    }

    // Cached once per redraw instead of recomputed by each of the 64 squares'
    // own bindings. Each of these is itself a full board-width scan (a legal-
    // move-list filter, or a king search) -- QML property bindings only
    // re-evaluate when a real dependency changes, so binding these here once
    // and having each BoardSquare do a cheap array/string comparison against
    // the result is strictly less JS work per redraw than before, with
    // identical visual output. This doesn't change *how many* e-ink refreshes
    // happen (Qt Quick already skips repainting a square whose computed color
    // didn't actually change either way) -- it only cuts redundant CPU work,
    // which matters for how quickly a frame is ready to hand to the display.
    property var selectedDestinations: boardScreen.destinationsFrom(boardScreen.selectedSquare)
    property string checkedSquare: boardScreen.checkedKingSquare()
    // Which color renders at the bottom of the board -- your side unless
    // manually flipped. The player bars below key off this so they follow
    // board orientation exactly (flip the board, the bars/clocks swap too),
    // the same behavior lichess mobile documents for its own Flip board.
    property string bottomColor: ((boardScreen.yourColor === "black") !== boardScreen.manualFlip) ? "black" : "white"
    property string topColor: bottomColor === "white" ? "black" : "white"

    // Player-bar lookups by side. Your own bar has no rating to show (the
    // backend only sends the opponent's) -- null keeps the suffix off.
    function nameFor(color) {
        if (color === boardScreen.yourColor) {
            return boardScreen.username.length > 0 ? boardScreen.username : "You"
        }
        return boardScreen.opponentName.length > 0 ? boardScreen.opponentName : "Opponent"
    }

    function ratingFor(color) {
        return color === boardScreen.yourColor ? null : boardScreen.opponentRating
    }

    function clockFor(color) {
        return color === "white" ? boardScreen.whiteTimeMs : boardScreen.blackTimeMs
    }

    function displayClockFor(color) {
        var now = Date.now() + boardScreen.clockPulse * 0
        var base = boardScreen.clockFor(color)
        if (!boardScreen.liveClockEnabled || color !== boardScreen.turn ||
                boardScreen.lastClockSyncMs <= 0 || boardScreen.gameOver) {
            return base
        }
        var elapsed = Math.floor(Math.max(0, now - boardScreen.lastClockSyncMs) / 1000) * 1000
        return Math.max(0, base - elapsed)
    }

    function displayFirstMoveTimeMs() {
        if (boardScreen.firstMoveTimeMs === null ||
                boardScreen.firstMoveTimeMs === undefined) {
            return null
        }
        var now = Date.now() + boardScreen.clockPulse * 0
        if (boardScreen.lastClockSyncMs <= 0) return boardScreen.firstMoveTimeMs
        var elapsed = Math.floor(Math.max(0, now - boardScreen.lastClockSyncMs) / 1000) * 1000
        return Math.max(0, boardScreen.firstMoveTimeMs - elapsed)
    }

    function gameActionsLabel() {
        if (boardScreen.pendingGameAction.length > 0) return "Working..."
        if (boardScreen.gameOver) return "Game over"
        if (boardScreen.drawOfferedByOpponent) return "Draw offer"
        if (boardScreen.takebackOfferedByOpponent) return "Takeback offer"
        if (boardScreen.opponentGone) return "Opponent left"
        if (boardScreen.drawOfferedByYou) return "Draw pending"
        if (boardScreen.takebackOfferedByYou) return "Takeback pending"
        return "Actions"
    }

    function topStatusText() {
        if (boardScreen.statusText.length > 0) return boardScreen.statusText
        if (boardScreen.gameOver) return "Game over"
        if (boardScreen.viewingHistory) {
            return "Viewing move " + boardScreen.historyIndex + " of " +
                boardScreen.moveHistory.length
        }
        if (moveRequestGate.pending !== null) {
            return "Submitting " + moveRequestGate.pending.from + "–" +
                moveRequestGate.pending.to +
                (moveRequestGate.pending.promotion
                    ? "=" + moveRequestGate.pending.promotion.toUpperCase()
                    : "")
        }
        if (boardScreen.pendingPremove !== null) {
            return "Premove: " + boardScreen.pendingPremove.from + "–" +
                boardScreen.pendingPremove.to
        }
        if (boardScreen.annotationMode) return "Annotating board"
        if (boardScreen.inCheck) {
            return boardScreen.turn === boardScreen.yourColor
                ? "Check — your move"
                : "Opponent is in check"
        }
        if (boardScreen.turn === boardScreen.yourColor &&
                boardScreen.displayFirstMoveTimeMs() !== null) {
            return "Move in ~" +
                Math.ceil(boardScreen.displayFirstMoveTimeMs() / 1000) + "s"
        }
        return boardScreen.turn === boardScreen.yourColor
            ? "Your move"
            : "Waiting for opponent"
    }

    function requestGameAction(message, action) {
        if (boardScreen.pendingGameAction.length > 0) return
        boardScreen.pendingGameAction = action
        boardScreen.backendSender(message)
        boardScreen.showGameActions = false
    }
    // filesRanks() itself is cheap, but it's read by all 64 squares plus 16
    // rank/file labels every redraw, each call allocating two fresh arrays --
    // same "compute once, index many" reasoning as selectedDestinations above.
    property var fr: boardScreen.filesRanks()
    // Full FEN decode, done once per redraw here rather than once per square
    // (64 full string walks otherwise, since pieceAt() used to re-parse the
    // whole placement field on every single call -- checkedKingSquare() alone
    // was already calling it 64 times by itself).
    property var pieceMap: boardScreen.buildPieceMap(boardScreen.fen)
    property var historicalLastMoveSquares: boardScreen.changedSquaresForHistory()
    property int materialBalance: boardScreen.calculateMaterialBalance(boardScreen.pieceMap)

    function buildPieceMap(fen) {
        var map = {}
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

    function changedSquaresForHistory() {
        if (!boardScreen.viewingHistory || boardScreen.historyIndex <= 0) return []
        return boardScreen.changedSquaresBetweenFens(
            boardScreen.positionHistory[boardScreen.historyIndex - 1],
            boardScreen.fen
        )
    }

    function changedSquaresBetweenFens(previousFen, currentFen) {
        var previous = boardScreen.buildPieceMap(previousFen)
        var current = boardScreen.buildPieceMap(currentFen)
        var files = ["a","b","c","d","e","f","g","h"]
        var ranks = ["1","2","3","4","5","6","7","8"]
        var out = []
        for (var r = 0; r < ranks.length; r++) {
            for (var f = 0; f < files.length; f++) {
                var square = files[f] + ranks[r]
                if ((previous[square] || "") !== (current[square] || "")) out.push(square)
            }
        }
        return out
    }

    function addRefreshSquare(squares, squareName) {
        if (squareName && squares.indexOf(squareName) === -1) squares.push(squareName)
    }

    function mergeChatHistory(messages) {
        var history = []
        for (var i = 0; i < messages.length; i++) {
            history.push(messages[i].username + ": " + messages[i].text)
        }
        var overlap = Math.min(history.length, boardScreen.chatMessages.length)
        while (overlap > 0) {
            var matches = true
            for (var j = 0; j < overlap; j++) {
                if (history[history.length - overlap + j] !== boardScreen.chatMessages[j]) {
                    matches = false
                    break
                }
            }
            if (matches) break
            overlap -= 1
        }
        boardScreen.chatMessages = history
            .concat(boardScreen.chatMessages.slice(overlap))
            .slice(-50)
    }

    // Deliberately keyed by the square name's own characters against
    // pieceMap (itself keyed the same way in buildPieceMap), not by indexing
    // into filesRanks()'s display-order arrays: FEN rows/columns are always
    // absolute (row0 = rank8, col0 = a-file) regardless of board
    // orientation. Indexing into filesRanks() instead only happened to work
    // for the unflipped (white) case, where display order and FEN order
    // coincide -- confirmed live via a real flipped (black) game: it showed
    // the wrong rank's/file's pieces entirely (e.g. Queen and King visibly
    // swapped on the back rank).
    function pieceAt(squareName) {
        return boardScreen.pieceMap[squareName] || ""
    }

    function isOwnPiece(piece) {
        if (piece === "") return false
        return boardScreen.yourColor === "white"
            ? piece === piece.toUpperCase()
            : piece === piece.toLowerCase()
    }

    function calculateMaterialBalance(map) {
        var values = {p: 1, n: 3, b: 3, r: 5, q: 9, k: 0}
        var balance = 0
        for (var squareName in map) {
            var piece = map[squareName]
            var value = values[piece.toLowerCase()] || 0
            balance += piece === piece.toUpperCase() ? value : -value
        }
        return balance
    }

    function materialAdvantageFor(color) {
        return Math.max(0, color === "white" ? boardScreen.materialBalance : -boardScreen.materialBalance)
    }

    function capturedPiecesFor(color) {
        return color === "white" ? boardScreen.capturedByWhite : boardScreen.capturedByBlack
    }

    // FEN piece char -> cburnett filename code (e.g. "K" -> "wK", "q" -> "bQ"),
    // matching frontend/assets/pieces/<code>.png. Replaced the earlier
    // Unicode-glyph glyphFor() map now that real piece art is bundled.
    function pieceCodeFor(pieceChar) {
        if (pieceChar === "") return ""
        var isWhite = pieceChar === pieceChar.toUpperCase()
        return (isWhite ? "w" : "b") + pieceChar.toUpperCase()
    }

    // Promotion letters from legalMoves are always lowercase ("q","r","b","n")
    // regardless of side -- color comes from whose turn it is, same as the
    // popup's own logic before this change.
    function promotionPieceCode(letter) {
        var sourcePiece = boardScreen.pendingPromotion
            ? boardScreen.pieceAt(boardScreen.pendingPromotion.from)
            : ""
        var isWhite = sourcePiece !== ""
            ? sourcePiece === sourcePiece.toUpperCase()
            : boardScreen.turn === "white"
        return (isWhite ? "w" : "b") + letter.toUpperCase()
    }

    function destinationsFrom(square) {
        var out = []
        for (var i = 0; i < boardScreen.legalMoves.length; i++) {
            if (boardScreen.legalMoves[i].from === square) out.push(boardScreen.legalMoves[i].to)
        }
        return out
    }

    // Distinct promotion letters legal for this exact from/to pair (queen, rook,
    // bishop, knight when this is a promoting pawn move; empty otherwise).
    // Previously the tap handler always auto-picked "q" here, silently making
    // underpromotion impossible -- every reference client offers a real choice.
    function promotionOptionsFor(from, to) {
        var opts = []
        for (var i = 0; i < boardScreen.legalMoves.length; i++) {
            var m = boardScreen.legalMoves[i]
            if (m.from === from && m.to === to && m.promotion) opts.push(m.promotion)
        }
        return opts
    }

    function beginMove(from, to) {
        if (boardScreen.destinationsFrom(from).indexOf(to) === -1) return false
        var promoOptions = boardScreen.promotionOptionsFor(from, to)
        if (promoOptions.length > 0 && boardScreen.autoQueenPromotion && promoOptions.indexOf("q") !== -1) {
            boardScreen.requestMove(from, to, "q")
        } else if (promoOptions.length > 0) {
            boardScreen.pendingPromotion = {from: from, to: to, options: promoOptions}
        } else {
            boardScreen.requestMove(from, to, null)
        }
        return true
    }

    function isPromotionPremove(from, to) {
        var piece = boardScreen.pieceAt(from)
        return (piece === "P" && to.charAt(1) === "8") ||
            (piece === "p" && to.charAt(1) === "1")
    }

    function queuePremove(from, to, promotion) {
        boardScreen.pendingPremove = {
            gameId: boardScreen.gameId,
            from: from,
            to: to,
            promotion: promotion
        }
        boardScreen.selectedSquare = ""
    }

    function beginPremove(from, to) {
        if (!boardScreen.isOwnPiece(boardScreen.pieceAt(from)) ||
                boardScreen.isOwnPiece(boardScreen.pieceAt(to)) || from === to) {
            return false
        }
        boardScreen.pendingPremove = null
        if (boardScreen.isPromotionPremove(from, to)) {
            if (boardScreen.autoQueenPromotion) {
                boardScreen.queuePremove(from, to, "q")
            } else {
                boardScreen.pendingPromotion = {
                    from: from,
                    to: to,
                    options: ["q", "r", "b", "n"],
                    premove: true
                }
            }
        } else {
            boardScreen.queuePremove(from, to, null)
        }
        return true
    }

    function cancelPremove() {
        boardScreen.pendingPremove = null
        boardScreen.selectedSquare = ""
    }

    function executePendingPremove() {
        if (boardScreen.pendingPremove === null ||
                boardScreen.turn !== boardScreen.yourColor) return
        var queued = boardScreen.pendingPremove
        boardScreen.pendingPremove = null
        boardScreen.selectedSquare = ""
        for (var i = 0; i < boardScreen.legalMoves.length; i++) {
            var move = boardScreen.legalMoves[i]
            if (move.from === queued.from && move.to === queued.to &&
                    (move.promotion || null) === queued.promotion) {
                boardScreen.requestMove(queued.from, queued.to, queued.promotion)
                return
            }
        }
        boardScreen.statusText = "Premove canceled: " + queued.from + "-" +
            queued.to + " is no longer legal."
    }

    function onSquareTapped(squareName) {
        if (boardScreen.gameOver || boardScreen.viewingHistory ||
                moveRequestGate.pending !== null) return
        // Not a correctness fix (legalMoves is always keyed to whoever's turn it
        // actually is, per the current FEN, so a tap during the opponent's turn
        // could never produce an illegal MakeMove) -- this is the UX gap flagged
        // in docs/chess-ux-gaps-vs-reference-apps.md #5: every reference client
        // disables input and shows whose turn it is rather than letting a player
        // tap around pointlessly waiting for a reply that never comes.
        if (boardScreen.turn !== boardScreen.yourColor) {
            if (!boardScreen.premovesEnabled) return
            if (boardScreen.selectedSquare === "") {
                if (boardScreen.isOwnPiece(boardScreen.pieceAt(squareName))) {
                    boardScreen.selectedSquare = squareName
                }
                return
            }
            if (boardScreen.selectedSquare === squareName) {
                boardScreen.selectedSquare = ""
                return
            }
            if (!boardScreen.beginPremove(boardScreen.selectedSquare, squareName)) {
                boardScreen.selectedSquare =
                    boardScreen.isOwnPiece(boardScreen.pieceAt(squareName)) ? squareName : ""
            }
            return
        }
        // A tap on the board can't do anything useful while a move is
        // already awaiting explicit Confirm/Cancel -- those buttons (or the
        // popup below) are the only way forward from here.
        if (boardScreen.pendingMoveConfirmation !== null) return
        if (boardScreen.selectedSquare === "") {
            if (boardScreen.isOwnPiece(boardScreen.pieceAt(squareName))) boardScreen.selectedSquare = squareName
            return
        }
        if (boardScreen.selectedSquare === squareName) {
            boardScreen.selectedSquare = ""
            return
        }
        if (boardScreen.beginMove(boardScreen.selectedSquare, squareName)) {
            return
        } else {
            boardScreen.selectedSquare = boardScreen.isOwnPiece(boardScreen.pieceAt(squareName)) ? squareName : ""
        }
    }

    function squareAtBoardPoint(x, y) {
        if (x < 0 || y < 0 || x >= grid.width || y >= grid.height) return ""
        var fileIndex = Math.floor(x / (grid.width / 8))
        var rankIndex = Math.floor(y / (grid.height / 8))
        return boardScreen.fr.files[fileIndex] + boardScreen.fr.ranks[rankIndex]
    }

    function onBoardGesture(from, to) {
        if (from === "" || to === "") return
        if (from === to) {
            boardScreen.onSquareTapped(to)
            return
        }
        if (boardScreen.gameOver || boardScreen.pendingMoveConfirmation !== null ||
                moveRequestGate.pending !== null ||
                !boardScreen.isOwnPiece(boardScreen.pieceAt(from))) {
            return
        }
        boardScreen.selectedSquare = from
        if (boardScreen.turn === boardScreen.yourColor) {
            if (!boardScreen.beginMove(from, to)) boardScreen.selectedSquare = ""
        } else if (boardScreen.premovesEnabled) {
            if (!boardScreen.beginPremove(from, to)) boardScreen.selectedSquare = ""
        } else {
            boardScreen.selectedSquare = ""
        }
    }

    Column {
        // Fixed (non-scrolling) chess frame: opponent bar, board, your bar --
        // the standard sides arrangement every reference client uses. The
        // action buttons / move list / chat below live in their own Flickable
        // so every control stays reachable regardless of how much of it is
        // visible at once; the board itself never scrolls off-screen.
        id: boardColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        spacing: theme.spacingXs

        PlayerBar {
            objectName: "topPlayerBar"
            width: parent.width - theme.pageTopRightInset
            darkMode: boardScreen.darkMode
            playerName: boardScreen.nameFor(boardScreen.topColor)
            rating: boardScreen.ratingFor(boardScreen.topColor)
            clockMs: boardScreen.displayClockFor(boardScreen.topColor)
            showClock: boardScreen.initialClockMs !== null
            active: boardScreen.turn === boardScreen.topColor
            lowTime: boardScreen.isLowTime(boardScreen.displayClockFor(boardScreen.topColor), boardScreen.initialClockMs)
            materialAdvantage: boardScreen.materialAdvantageFor(boardScreen.topColor)
            capturedPieces: boardScreen.capturedPiecesFor(boardScreen.topColor)
            statusText: boardScreen.topStatusText()
            statusEmphasized: !boardScreen.gameOver &&
                boardScreen.turn === boardScreen.yourColor
        }

        Row {
            spacing: theme.spacingXs

            Column {
                id: rankLabels
                Repeater {
                    model: 8
                    Text {
                        required property int index
                        width: 64
                        height: grid.height / 8
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: boardScreen.fr.ranks[index]
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
                    // Width-driven on the real (portrait) panel; the height
                    // cap only exists so a shorter/landscape host (the PC
                    // emulator) still gets a usable, non-overflowing board.
                    width: Math.min(boardColumn.width - rankLabels.width - theme.spacingXs, boardScreen.height * 0.5)
                    height: width

                    Repeater {
                        model: 64
                        BoardSquare {
                            required property int index
                            width: grid.width / 8
                            height: grid.height / 8
                            property int fileIdx: index % 8
                            property int rankIdx: Math.floor(index / 8)
                            squareName: boardScreen.fr.files[fileIdx] + boardScreen.fr.ranks[rankIdx]
                            isLight: (fileIdx + rankIdx) % 2 === 0
                            darkMode: boardScreen.darkMode
                            pieceCode: boardScreen.pieceCodeFor(boardScreen.pieceAt(squareName))
                            isHighlighted: boardScreen.selectedSquare === squareName ||
                                (!boardScreen.minimalHighlights && boardScreen.selectedDestinations.indexOf(squareName) !== -1)
                            isSelected: boardScreen.selectedSquare === squareName
                            isLegalDestination: !boardScreen.minimalHighlights &&
                                boardScreen.selectedDestinations.indexOf(squareName) !== -1
                            isLastMove: boardScreen.isLastMoveSquare(squareName)
                            isCheckSquare: squareName === boardScreen.checkedSquare
                            isPremoveSource: boardScreen.pendingPremove !== null &&
                                boardScreen.pendingPremove.from === squareName
                            isPremoveDestination: boardScreen.pendingPremove !== null &&
                                boardScreen.pendingPremove.to === squareName
                            flashRefresh: boardScreen.flashSquares.indexOf(squareName) !== -1
                        }
                    }
                }

                MouseArea {
                    id: boardInput
                    anchors.fill: grid
                    property string pressSquare: ""
                    property real pressX: 0
                    property real pressY: 0
                    preventStealing: true
                    onPressed: (mouse) => {
                        pressSquare = boardScreen.squareAtBoardPoint(mouse.x, mouse.y)
                        pressX = mouse.x
                        pressY = mouse.y
                    }
                    onReleased: (mouse) => {
                        var releaseSquare = boardScreen.squareAtBoardPoint(mouse.x, mouse.y)
                        var dx = mouse.x - pressX
                        var dy = mouse.y - pressY
                        if (dx * dx + dy * dy < theme.boardDragThreshold * theme.boardDragThreshold) {
                            releaseSquare = pressSquare
                        }
                        if (boardScreen.annotationMode) {
                            boardScreen.toggleAnnotation(pressSquare, releaseSquare)
                        } else {
                            boardScreen.onBoardGesture(pressSquare, releaseSquare)
                        }
                        pressSquare = ""
                    }
                    onCanceled: pressSquare = ""
                }

                Canvas {
                    id: annotationCanvas
                    anchors.fill: parent
                    property var annotations: boardScreen.boardAnnotations
                    property var displayOrder: boardScreen.fr
                    property color outerInk: theme.background
                    property color innerInk: theme.text

                    onAnnotationsChanged: requestPaint()
                    onDisplayOrderChanged: requestPaint()
                    onOuterInkChanged: requestPaint()
                    onInnerInkChanged: requestPaint()

                    function squareCenter(squareName) {
                        var fileIndex = displayOrder.files.indexOf(squareName.charAt(0))
                        var rankIndex = displayOrder.ranks.indexOf(squareName.charAt(1))
                        if (fileIndex < 0 || rankIndex < 0) return null
                        return {
                            x: (fileIndex + 0.5) * width / 8,
                            y: (rankIndex + 0.5) * height / 8
                        }
                    }

                    function strokeLine(context, start, end, color, lineWidth) {
                        context.beginPath()
                        context.moveTo(start.x, start.y)
                        context.lineTo(end.x, end.y)
                        context.strokeStyle = color
                        context.lineWidth = lineWidth
                        context.lineCap = "round"
                        context.lineJoin = "round"
                        context.stroke()
                    }

                    function drawArrow(context, start, end, color, lineWidth) {
                        var angle = Math.atan2(end.y - start.y, end.x - start.x)
                        var squareSize = width / 8
                        var tip = {
                            x: end.x - Math.cos(angle) * squareSize * 0.18,
                            y: end.y - Math.sin(angle) * squareSize * 0.18
                        }
                        var lineEnd = {
                            x: tip.x - Math.cos(angle) * squareSize * 0.14,
                            y: tip.y - Math.sin(angle) * squareSize * 0.14
                        }
                        strokeLine(context, start, lineEnd, color, lineWidth)
                        context.beginPath()
                        context.moveTo(tip.x, tip.y)
                        context.lineTo(
                            tip.x - Math.cos(angle - Math.PI / 5) * squareSize * 0.32,
                            tip.y - Math.sin(angle - Math.PI / 5) * squareSize * 0.32
                        )
                        context.lineTo(
                            tip.x - Math.cos(angle + Math.PI / 5) * squareSize * 0.32,
                            tip.y - Math.sin(angle + Math.PI / 5) * squareSize * 0.32
                        )
                        context.closePath()
                        context.fillStyle = color
                        context.fill()
                    }

                    function drawRing(context, center, color, lineWidth) {
                        context.beginPath()
                        context.arc(center.x, center.y, width / 8 * 0.34, 0, Math.PI * 2)
                        context.strokeStyle = color
                        context.lineWidth = lineWidth
                        context.stroke()
                    }

                    onPaint: {
                        var context = getContext("2d")
                        context.clearRect(0, 0, width, height)
                        for (var i = 0; i < annotations.length; i++) {
                            var annotation = annotations[i]
                            var start = squareCenter(annotation.from)
                            var end = squareCenter(annotation.to)
                            if (start === null || end === null) continue
                            if (annotation.from === annotation.to) {
                                drawRing(context, start, outerInk, Math.max(14, width * 0.018))
                                drawRing(context, start, innerInk, Math.max(7, width * 0.009))
                            } else {
                                drawArrow(context, start, end, outerInk, Math.max(18, width * 0.022))
                                drawArrow(context, start, end, innerInk, Math.max(9, width * 0.011))
                            }
                        }
                    }
                }

            }
        }

        Row {
            spacing: theme.spacingXs
            Item { width: 64; height: 1 }
            Row {
                width: grid.width
                Repeater {
                    model: 8
                    Text {
                        required property int index
                        width: grid.width / 8
                        horizontalAlignment: Text.AlignHCenter
                        text: boardScreen.fr.files[index]
                        font.pixelSize: theme.fontSmall
                        color: theme.text
                    }
                }
            }
        }

        PlayerBar {
            width: parent.width
            darkMode: boardScreen.darkMode
            playerName: boardScreen.nameFor(boardScreen.bottomColor)
            rating: boardScreen.ratingFor(boardScreen.bottomColor)
            clockMs: boardScreen.displayClockFor(boardScreen.bottomColor)
            showClock: boardScreen.initialClockMs !== null
            active: boardScreen.turn === boardScreen.bottomColor
            lowTime: boardScreen.isLowTime(boardScreen.displayClockFor(boardScreen.bottomColor), boardScreen.initialClockMs)
            materialAdvantage: boardScreen.materialAdvantageFor(boardScreen.bottomColor)
            capturedPieces: boardScreen.capturedPiecesFor(boardScreen.bottomColor)
        }
    }

    Row {
        id: boardToolbar
        anchors.top: boardColumn.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.spacingXs
        spacing: theme.spacingXs

        BoardToolButton {
            width: (parent.width - parent.spacing * 2) / 3
            text: boardScreen.gameActionsLabel()
            highlighted: boardScreen.pendingGameAction.length > 0 ||
                boardScreen.gameOver ||
                boardScreen.drawOfferedByOpponent ||
                boardScreen.takebackOfferedByOpponent ||
                boardScreen.opponentGone
            onClicked: {
                if (boardScreen.pendingGameAction.length === 0) {
                    boardScreen.showGameActions = true
                }
            }
        }
        BoardToolButton {
            width: (parent.width - parent.spacing * 2) / 3
            text: "Moves"
            highlighted: boardScreen.viewingHistory
            onClicked: boardScreen.showMoves = true
        }
        BoardToolButton {
            width: (parent.width - parent.spacing * 2) / 3
            text: "Chat"
            enabled: boardScreen.canChat
            onClicked: boardScreen.showChat = true
        }
    }

    AppDialog {
        anchors.fill: parent
        visible: boardScreen.showGameActions
        darkMode: boardScreen.darkMode
        title: "Game actions"
        onDismissed: boardScreen.showGameActions = false

        Text {
            width: parent.width
            text: boardScreen.gameDescription
            visible: text.length > 0
            font.pixelSize: theme.fontSmall
            horizontalAlignment: Text.AlignHCenter
            color: theme.textMuted
        }

        AppButton {
            width: parent.width
            text: "Review this game"
            highlighted: true
            visible: boardScreen.gameOver && boardScreen.gameId.length > 0
            onClicked: boardScreen.openGameReview(boardScreen.gameId, {
                game_id: boardScreen.gameId,
                opponent_name: boardScreen.opponentName,
                opponent_rating: boardScreen.opponentRating,
                result: boardScreen.gameResult,
                termination: boardScreen.gameReason,
                your_color: boardScreen.yourColor
            })
        }
        AppButton {
            width: parent.width
            text: "New game"
            visible: boardScreen.gameOver
            onClicked: boardScreen.navigateTo("SeekScreen.qml")
        }

        ConfirmAction {
            id: acceptDrawAction
            width: parent.width
            actionText: "Accept draw"
            confirmText: "Confirm draw"
            cancelText: "Keep playing"
            busyText: "Accepting draw"
            busy: boardScreen.pendingGameAction === "Draw"
            prominent: true
            critical: true
            visible: !boardScreen.gameOver && boardScreen.drawOfferedByOpponent
            onConfirmed: boardScreen.requestGameAction(
                {type: "DrawAction", accept: true}, "Draw")
        }
        AppButton {
            width: parent.width
            text: "Decline draw"
            visible: !boardScreen.gameOver && boardScreen.drawOfferedByOpponent
            onClicked: boardScreen.requestGameAction(
                {type: "DrawAction", accept: false}, "Draw")
        }
        ConfirmAction {
            id: drawOfferAction
            width: parent.width
            actionText: "Offer draw"
            confirmText: "Confirm draw offer"
            cancelText: "Cancel draw confirmation"
            busyText: "Sending draw offer"
            busy: boardScreen.pendingGameAction === "Draw"
            visible: !boardScreen.gameOver && boardScreen.canOfferDraw &&
                !boardScreen.drawOfferedByOpponent
            onConfirmed: boardScreen.requestGameAction(
                {type: "DrawAction", accept: true}, "Draw")
        }
        Text {
            width: parent.width
            text: "Draw offer sent"
            visible: !boardScreen.gameOver && boardScreen.drawOfferedByYou
            font.pixelSize: theme.fontBody
            horizontalAlignment: Text.AlignHCenter
            color: theme.text
        }

        AppButton {
            width: parent.width
            text: "Accept takeback"
            highlighted: true
            visible: !boardScreen.gameOver && boardScreen.takebackOfferedByOpponent
            onClicked: boardScreen.requestGameAction(
                {type: "TakebackAction", accept: true}, "Takeback")
        }
        AppButton {
            width: parent.width
            text: "Decline takeback"
            visible: !boardScreen.gameOver && boardScreen.takebackOfferedByOpponent
            onClicked: boardScreen.requestGameAction(
                {type: "TakebackAction", accept: false}, "Takeback")
        }
        AppButton {
            width: parent.width
            text: "Offer takeback"
            visible: !boardScreen.gameOver && boardScreen.canOfferTakeback &&
                !boardScreen.takebackOfferedByOpponent
            onClicked: boardScreen.requestGameAction(
                {type: "TakebackAction", accept: true}, "Takeback")
        }
        AppButton {
            width: parent.width
            text: "Cancel takeback offer"
            visible: !boardScreen.gameOver && boardScreen.takebackOfferedByYou
            onClicked: boardScreen.requestGameAction(
                {type: "TakebackAction", accept: false}, "Takeback")
        }

        ConfirmAction {
            id: abortAction
            width: parent.width
            actionText: "Abort"
            confirmText: "Confirm abort"
            cancelText: "Cancel abort"
            busyText: "Aborting game"
            busy: boardScreen.pendingGameAction === "Abort"
            critical: true
            visible: !boardScreen.gameOver && boardScreen.canAbort
            onConfirmed: boardScreen.requestGameAction({type: "Abort"}, "Abort")
        }
        ConfirmAction {
            id: berserkAction
            width: parent.width
            actionText: "Berserk (halve clock)"
            confirmText: "Confirm Berserk"
            cancelText: "Cancel Berserk"
            busyText: "Berserk requested"
            busy: boardScreen.pendingGameAction === "Berserk"
            visible: !boardScreen.gameOver && boardScreen.canBerserk
            onConfirmed: boardScreen.requestGameAction({type: "Berserk"}, "Berserk")
        }
        ConfirmAction {
            id: giveTimeAction
            width: parent.width
            actionText: "Give opponent 15s"
            confirmText: "Confirm 15s gift"
            cancelText: "Cancel time gift"
            busyText: "Adding 15 seconds"
            busy: boardScreen.pendingGameAction === "AddTime"
            visible: !boardScreen.gameOver && boardScreen.canGiveTime
            onConfirmed: boardScreen.requestGameAction(
                {type: "AddTime", seconds: 15}, "AddTime")
        }
        AppButton {
            width: parent.width
            text: "Claim victory" +
                (boardScreen.claimWinInSeconds > 0
                    ? " (~" + boardScreen.claimWinInSeconds + "s)"
                    : "")
            highlighted: true
            visible: !boardScreen.gameOver && boardScreen.opponentGone
            onClicked: boardScreen.requestGameAction(
                {type: "ClaimVictory"}, "ClaimVictory")
        }
        ConfirmAction {
            id: claimDrawAction
            width: parent.width
            actionText: "Claim draw"
            confirmText: "Confirm draw claim"
            cancelText: "Keep playing"
            busyText: "Claiming draw"
            busy: boardScreen.pendingGameAction === "ClaimDraw"
            critical: true
            visible: !boardScreen.gameOver && boardScreen.opponentGone
            onConfirmed: boardScreen.requestGameAction(
                {type: "ClaimDraw"}, "ClaimDraw")
        }
        AppButton {
            width: parent.width
            text: "Cancel premove"
            visible: !boardScreen.gameOver && boardScreen.pendingPremove !== null
            onClicked: {
                boardScreen.cancelPremove()
                boardScreen.showGameActions = false
            }
        }

        AppButton {
            width: parent.width
            text: "Flip board"
            onClicked: {
                boardScreen.manualFlip = !boardScreen.manualFlip
                boardScreen.showGameActions = false
            }
        }
        AppButton {
            width: parent.width
            text: boardScreen.annotationMode ? "Stop annotating" : "Annotate board"
            highlighted: boardScreen.annotationMode
            onClicked: {
                boardScreen.setAnnotationMode(!boardScreen.annotationMode)
                boardScreen.showGameActions = false
            }
        }
        AppButton {
            width: parent.width
            text: "Clear marks"
            visible: boardScreen.boardAnnotations.length > 0
            onClicked: {
                boardScreen.clearAnnotations()
                boardScreen.showGameActions = false
            }
        }

        ConfirmAction {
            id: resignAction
            width: parent.width
            actionText: "Resign"
            confirmText: "Confirm resignation"
            cancelText: "Cancel resignation"
            busyText: "Resigning game"
            busy: boardScreen.pendingGameAction === "Resign"
            critical: true
            visible: !boardScreen.gameOver && !boardScreen.canAbort
            onConfirmed: boardScreen.requestGameAction({type: "Resign"}, "Resign")
        }
        AppButton {
            width: parent.width
            text: "Close"
            onClicked: boardScreen.showGameActions = false
        }
    }

    AppDialog {
        anchors.fill: parent
        visible: boardScreen.showMoves
        darkMode: boardScreen.darkMode
        title: "Moves"
        onDismissed: boardScreen.showMoves = false

        Text {
            width: parent.width
            text: "No moves yet"
            visible: boardScreen.moveHistory.length === 0
            font.pixelSize: theme.fontBody
            horizontalAlignment: Text.AlignHCenter
            color: theme.textMuted
        }
        AppButton {
            width: parent.width
            text: "Return to live position"
            highlighted: true
            visible: boardScreen.viewingHistory
            onClicked: {
                boardScreen.returnToLive()
                boardScreen.showMoves = false
            }
        }
        Flow {
            width: parent.width
            spacing: theme.spacingXs

            Repeater {
                model: boardScreen.moveTokens()

                MoveTokenButton {
                    required property var modelData
                    darkMode: boardScreen.darkMode
                    text: modelData.label
                    selected: modelData.fenIndex === boardScreen.historyIndex
                    onClicked: {
                        boardScreen.showHistoryPosition(modelData.fenIndex)
                        boardScreen.showMoves = false
                    }
                }
            }
        }
        AppButton {
            width: parent.width
            text: "Close"
            onClicked: boardScreen.showMoves = false
        }
    }

    AppDialog {
        anchors.fill: parent
        visible: boardScreen.showChat
        darkMode: boardScreen.darkMode
        title: "Player chat"
        onDismissed: boardScreen.showChat = false

        Text {
            width: parent.width
            text: boardScreen.chatMessages.length > 0
                ? boardScreen.chatMessages.join("\n")
                : "No messages yet"
            font.pixelSize: theme.fontSmall
            wrapMode: Text.WordWrap
            color: boardScreen.chatMessages.length > 0 ? theme.text : theme.textMuted
        }
        Row {
            width: parent.width
            spacing: theme.spacingXs

            AppTextField {
                id: chatInputField
                width: parent.width - sendChatButton.width - parent.spacing
                placeholderText: "Message opponent"
            }
            AppButton {
                id: sendChatButton
                text: "Send"
                enabled: chatInputField.text.length > 0
                onClicked: {
                    boardScreen.backendSender({type: "SendChat", text: chatInputField.text})
                    chatInputField.text = ""
                }
            }
        }
        AppButton {
            width: parent.width
            text: "Close"
            onClicked: boardScreen.showChat = false
        }
    }

    AppButton {
        id: backButton
        objectName: "boardBackButton"
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        text: "Back to Home"
        visible: boardScreen.canNavigateHome
        enabled: boardScreen.canNavigateHome
        onClicked: boardScreen.navigateTo("HomeScreen.qml")
    }

    PromotionDialog {
        anchors.fill: parent
        visible: boardScreen.pendingPromotion !== null
        darkMode: boardScreen.darkMode
        options: boardScreen.pendingPromotion ? boardScreen.pendingPromotion.options : []
        pieceCodeFor: function(piece) {
            return boardScreen.promotionPieceCode(piece)
        }
        onChosen: (piece) => {
            var from = boardScreen.pendingPromotion.from
            var to = boardScreen.pendingPromotion.to
            var isPremove = boardScreen.pendingPromotion.premove || false
            boardScreen.pendingPromotion = null
            if (isPremove) {
                boardScreen.queuePremove(from, to, piece)
            } else {
                boardScreen.requestMove(from, to, piece)
            }
        }
    }

    AppDialog {
        anchors.fill: parent
        visible: boardScreen.pendingMoveConfirmation !== null
        darkMode: boardScreen.darkMode
        dismissOnBackground: false
        title: boardScreen.pendingMoveConfirmation
            ? "Confirm " + boardScreen.pendingMoveConfirmation.from + "–" +
                boardScreen.pendingMoveConfirmation.to +
                (boardScreen.pendingMoveConfirmation.promotion
                    ? "=" + boardScreen.pendingMoveConfirmation.promotion.toUpperCase()
                    : "")
            : ""

        Row {
            width: parent.width
            spacing: theme.spacingXs

            AppButton {
                width: (parent.width - parent.spacing) / 2
                text: "Confirm"
                highlighted: true
                onClicked: boardScreen.confirmPendingMove()
            }
            AppButton {
                width: (parent.width - parent.spacing) / 2
                text: "Cancel"
                onClicked: boardScreen.cancelPendingMove()
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "BoardState") {
            var nextLastMove = msg.last_move || null
            var positionChanged = boardScreen.liveFen !== msg.fen ||
                (boardScreen.gameId.length > 0 && boardScreen.gameId !== (msg.game_id || ""))
            if (boardScreen.liveFen !== "" && positionChanged) {
                var refreshSquares = boardScreen.changedSquaresBetweenFens(boardScreen.liveFen, msg.fen)
                if (boardScreen.lastMove !== null) {
                    boardScreen.addRefreshSquare(refreshSquares, boardScreen.lastMove[0])
                    boardScreen.addRefreshSquare(refreshSquares, boardScreen.lastMove[1])
                }
                if (nextLastMove !== null) {
                    boardScreen.addRefreshSquare(refreshSquares, nextLastMove[0])
                    boardScreen.addRefreshSquare(refreshSquares, nextLastMove[1])
                }
                boardScreen.addRefreshSquare(refreshSquares, boardScreen.checkedSquare)
                boardScreen.addRefreshSquare(
                    refreshSquares,
                    boardScreen.checkedKingSquareFor(msg.fen, msg.turn, msg.in_check || false)
                )
                boardScreen.flashSquares = refreshSquares
                boardFlashTimer.restart()
            }
            if (positionChanged) boardScreen.clearAnnotations()
            boardScreen.gameId = msg.game_id || ""
            boardScreen.liveFen = msg.fen
            boardScreen.fen = msg.fen
            boardScreen.positionHistory = msg.position_history || [msg.fen]
            boardScreen.historyIndex = boardScreen.positionHistory.length - 1
            boardScreen.turn = msg.turn
            boardScreen.whiteTimeMs = msg.white_time_ms
            boardScreen.blackTimeMs = msg.black_time_ms
            boardScreen.lastClockSyncMs = Date.now()
            boardScreen.clockPulse += 1
            boardScreen.initialClockMs = msg.initial_clock_ms !== undefined ? msg.initial_clock_ms : null
            boardScreen.legalMoves = msg.legal_moves
            boardScreen.lastMove = msg.last_move || null
            boardScreen.inCheck = msg.in_check || false
            boardScreen.yourColor = msg.your_color || "white"
            boardScreen.drawOfferedByOpponent = msg.draw_offered_by_opponent || false
            boardScreen.takebackOfferedByOpponent = msg.takeback_offered_by_opponent || false
            boardScreen.drawOfferedByYou = msg.draw_offered_by_you || false
            boardScreen.takebackOfferedByYou = msg.takeback_offered_by_you || false
            boardScreen.canAbort = msg.can_abort || false
            boardScreen.canBerserk = msg.can_berserk || false
            boardScreen.canOfferDraw = msg.can_offer_draw || false
            boardScreen.canOfferTakeback = msg.can_offer_takeback || false
            boardScreen.canGiveTime = msg.can_give_time || false
            boardScreen.canChat = msg.can_chat || false
            if (!boardScreen.canOfferDraw) drawOfferAction.reset()
            boardScreen.moveHistory = msg.move_history || []
            boardScreen.capturedByWhite = msg.captured_by_white || []
            boardScreen.capturedByBlack = msg.captured_by_black || []
            boardScreen.opponentName = msg.opponent_name || ""
            boardScreen.opponentRating = msg.opponent_rating !== undefined ? msg.opponent_rating : null
            boardScreen.gameDescription = msg.game_description || ""
            boardScreen.firstMoveTimeMs = msg.first_move_time_ms !== undefined
                ? msg.first_move_time_ms
                : null
            resignAction.reset()
            abortAction.reset()
            berserkAction.reset()
            acceptDrawAction.reset()
            claimDrawAction.reset()
            giveTimeAction.reset()
            // A RatingDiff for a previous game that never got consumed (its
            // own GameOver never arrived on this screen, e.g. after a
            // Back-to-Home-and-Resume round trip) must not bleed into this
            // new game's eventual GameOver text.
            boardScreen.pendingRatingDiffText = ""
            boardScreen.statusText = ""
            boardScreen.gameOver = false
            boardScreen.gameResult = ""
            boardScreen.gameReason = ""
            moveRequestGate.resolve(boardScreen.gameId, nextLastMove)
            if (boardScreen.pendingPremove !== null &&
                    boardScreen.pendingPremove.gameId !== boardScreen.gameId) {
                boardScreen.cancelPremove()
            }
            boardScreen.executePendingPremove()
        } else if (msg.type === "GameOver") {
            boardScreen.returnToLive()
            boardScreen.whiteTimeMs = boardScreen.displayClockFor("white")
            boardScreen.blackTimeMs = boardScreen.displayClockFor("black")
            boardScreen.lastClockSyncMs = 0
            // msg.result is "draw", the winning color, or -- for a no-winner
            // ending that wasn't actually a draw either (aborted, noStart,
            // cheat, ...) -- the raw status itself (see backend_app.rs's
            // game_over_result). Shown from the local player's own
            // perspective (yourColor) rather than raw white/black for an
            // actual win/loss, so "you resigned" reads as "You lost", not
            // just an opaque color name; the raw-status case is titlecased
            // as-is since there's no "you" to attribute it to.
            var outcome
            if (msg.result === "draw") {
                outcome = "Draw"
                boardScreen.gameResult = "draw"
            } else if (msg.result === "white" || msg.result === "black") {
                outcome = msg.result === boardScreen.yourColor ? "You won" : "You lost"
                boardScreen.gameResult = msg.result === boardScreen.yourColor ? "win" : "loss"
            } else {
                outcome = msg.result.charAt(0).toUpperCase() + msg.result.slice(1)
                boardScreen.gameResult = msg.result
            }
            boardScreen.gameOver = true
            boardScreen.gameReason = msg.reason
            boardScreen.selectedSquare = ""
            boardScreen.legalMoves = []
            boardScreen.pendingPromotion = null
            boardScreen.pendingMoveConfirmation = null
            moveRequestGate.clear()
            boardScreen.pendingPremove = null
            resignAction.reset()
            abortAction.reset()
            berserkAction.reset()
            acceptDrawAction.reset()
            claimDrawAction.reset()
            giveTimeAction.reset()
            boardScreen.pendingGameAction = ""
            boardScreen.statusText = "Game over: " + outcome +
                (msg.reason && msg.reason.length > 0 ? " (" + msg.reason + ")" : "")
            if (boardScreen.pendingRatingDiffText.length > 0) {
                boardScreen.statusText += boardScreen.pendingRatingDiffText
                boardScreen.pendingRatingDiffText = ""
            }
        } else if (msg.type === "RatingDiff") {
            var diffText = "  (" + (msg.rating_diff > 0 ? "+" : "") + msg.rating_diff + ")"
            if (boardScreen.statusText.indexOf("Game over") === 0) {
                boardScreen.statusText += diffText
            } else {
                boardScreen.pendingRatingDiffText = diffText
            }
        } else if (msg.type === "GameActionCompleted") {
            if (boardScreen.pendingGameAction === msg.action) {
                boardScreen.pendingGameAction = ""
            }
            if (msg.action === "Berserk") {
                boardScreen.canBerserk = false
                berserkAction.reset()
                boardScreen.statusText = "Berserk activated"
            } else if (msg.action === "AddTime") {
                boardScreen.statusText = "15 seconds added to opponent"
            }
        } else if (msg.type === "MoveSubmitted") {
            moveRequestGate.acknowledge(
                msg.game_id, msg.from, msg.to, msg.promotion || null)
        } else if (msg.type === "MoveRejected") {
            boardScreen.statusText = "Move rejected: " + msg.reason
            boardScreen.selectedSquare = ""
            moveRequestGate.clear()
        } else if (msg.type === "Reconnecting") {
            boardScreen.statusText = "Reconnecting..."
        } else if (msg.type === "OpponentGone") {
            boardScreen.opponentGone = msg.gone
            boardScreen.claimWinInSeconds = msg.claim_win_in_seconds || 0
        } else if (msg.type === "ChatMessage") {
            // Capped rather than left to grow for a whole (possibly
            // correspondence-length) game's entire chat history -- unbounded
            // otherwise, and nothing here ever needs more than recent context.
            boardScreen.chatMessages = boardScreen.chatMessages.concat([msg.username + ": " + msg.text]).slice(-50)
        } else if (msg.type === "ChatHistory") {
            boardScreen.mergeChatHistory(msg.messages || [])
        } else if (msg.type === "ErrorMsg") {
            // Otherwise a failed draw/takeback/abort/claim (e.g. "Takeback not
            // possible") only ever reached main.qml's console.warn -- invisible
            // to an actual player on-device.
            boardScreen.statusText = msg.message
            boardScreen.pendingGameAction = ""
        }
    }
}
