import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: boardScreen
    anchors.fill: parent
    color: boardScreen.darkMode ? "#2b2b28" : "white"
    property var backendSender
    property var navigateTo
    property bool darkMode: false

    property string fen: ""
    property string turn: "white"
    property int whiteTimeMs: 0
    property int blackTimeMs: 0
    property var legalMoves: []
    property string selectedSquare: ""
    property string statusText: ""
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

    // Display-order files/ranks, flipped when playing black so the local player's
    // own pieces render at the bottom, matching standard chess-app convention.
    // Written as two plain literals rather than slice().reverse() -- qmllint
    // infers a QVariantList type for these array literals under Qt6's stricter
    // QML type system, which doesn't reliably expose Array.prototype methods.
    function filesRanks() {
        if (boardScreen.yourColor === "black") {
            return {files: ["h","g","f","e","d","c","b","a"], ranks: ["1","2","3","4","5","6","7","8"]}
        }
        return {files: ["a","b","c","d","e","f","g","h"], ranks: ["8","7","6","5","4","3","2","1"]}
    }

    function isLastMoveSquare(sq) {
        return boardScreen.lastMove !== null && (sq === boardScreen.lastMove[0] || sq === boardScreen.lastMove[1])
    }

    // Finds the square of whichever king is currently in check (always the side
    // to move's own king -- you can't end your move still in check). Iterates a
    // fixed absolute a1..h8 sweep rather than the display-order filesRanks(), since
    // square *names* don't depend on board orientation, only where they're drawn.
    function checkedKingSquare() {
        if (!boardScreen.inCheck) return ""
        var kingChar = boardScreen.turn === "white" ? "K" : "k"
        var files = ["a","b","c","d","e","f","g","h"]
        var ranks = ["1","2","3","4","5","6","7","8"]
        for (var r = 0; r < ranks.length; r++) {
            for (var f = 0; f < files.length; f++) {
                var sq = files[f] + ranks[r]
                if (boardScreen.pieceAt(sq) === kingChar) return sq
            }
        }
        return ""
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

    function pieceAt(squareName) {
        // Minimal FEN board decode: walk the piece-placement field only.
        var placement = boardScreen.fen.split(" ")[0]
        var rows = placement.split("/")
        var fr = boardScreen.filesRanks()
        var rankIndex = fr.ranks.indexOf(squareName[1])
        var fileIndex = fr.files.indexOf(squareName[0])
        if (rankIndex < 0 || fileIndex < 0) return ""
        var row = rows[rankIndex]
        var col = 0
        for (var i = 0; i < row.length; i++) {
            var c = row[i]
            if (c >= '1' && c <= '8') {
                col += parseInt(c)
            } else {
                if (col === fileIndex) return c
                col += 1
            }
        }
        return ""
    }

    function glyphFor(pieceChar) {
        var map = {
            "K": "♔", "Q": "♕", "R": "♖", "B": "♗", "N": "♘", "P": "♙",
            "k": "♚", "q": "♛", "r": "♜", "b": "♝", "n": "♞", "p": "♟"
        }
        return map[pieceChar] || ""
    }

    function destinationsFrom(square) {
        var out = []
        for (var i = 0; i < boardScreen.legalMoves.length; i++) {
            if (boardScreen.legalMoves[i].from === square) out.push(boardScreen.legalMoves[i].to)
        }
        return out
    }

    function onSquareTapped(squareName) {
        if (boardScreen.selectedSquare === "") {
            if (boardScreen.pieceAt(squareName) !== "") boardScreen.selectedSquare = squareName
            return
        }
        if (boardScreen.selectedSquare === squareName) {
            boardScreen.selectedSquare = ""
            return
        }
        var dests = boardScreen.destinationsFrom(boardScreen.selectedSquare)
        if (dests.indexOf(squareName) !== -1) {
            var promo = null
            for (var i = 0; i < boardScreen.legalMoves.length; i++) {
                if (boardScreen.legalMoves[i].from === boardScreen.selectedSquare && boardScreen.legalMoves[i].to === squareName && boardScreen.legalMoves[i].promotion) {
                    if (promo === null) {
                        promo = boardScreen.legalMoves[i].promotion
                    }
                    if (boardScreen.legalMoves[i].promotion === "q") {
                        promo = boardScreen.legalMoves[i].promotion
                        break
                    }
                }
            }
            boardScreen.backendSender({type: "MakeMove", from: boardScreen.selectedSquare, to: squareName, promotion: promo})
            boardScreen.selectedSquare = ""
        } else {
            boardScreen.selectedSquare = boardScreen.pieceAt(squareName) !== "" ? squareName : ""
        }
    }

    Column {
        anchors.fill: parent
        spacing: 8

        Text {
            // No local ticking (see the removed Timer's comment below): this shows
            // the clock exactly as of the last authoritative BoardState from the
            // server -- i.e. it updates on moves/reconnects, not every second.
            text: "Black: " + Math.floor(boardScreen.blackTimeMs / 1000) + "s"
            font.pixelSize: 28
            color: boardScreen.darkMode ? "#e6e2d8" : "black"
        }

        Row {
            spacing: 4

            Column {
                id: rankLabels
                Repeater {
                    model: 8
                    Text {
                        required property int index
                        width: 24
                        height: grid.height / 8
                        verticalAlignment: Text.AlignVCenter
                        horizontalAlignment: Text.AlignHCenter
                        text: boardScreen.filesRanks().ranks[index]
                        font.pixelSize: 16
                        color: boardScreen.darkMode ? "#e6e2d8" : "black"
                    }
                }
            }

            Grid {
                id: grid
                columns: 8
                rows: 8
                width: Math.min(boardScreen.width - rankLabels.width - 4, boardScreen.height - 200)
                height: width

                Repeater {
                    model: 64
                    BoardSquare {
                        required property int index
                        width: grid.width / 8
                        height: grid.height / 8
                        property int fileIdx: index % 8
                        property int rankIdx: Math.floor(index / 8)
                        squareName: boardScreen.filesRanks().files[fileIdx] + boardScreen.filesRanks().ranks[rankIdx]
                        isLight: (fileIdx + rankIdx) % 2 === 0
                        darkMode: boardScreen.darkMode
                        pieceGlyph: boardScreen.glyphFor(boardScreen.pieceAt(squareName))
                        isHighlighted: boardScreen.selectedSquare === squareName || boardScreen.selectedDestinations.indexOf(squareName) !== -1
                        isLastMove: boardScreen.isLastMoveSquare(squareName)
                        isCheckSquare: squareName === boardScreen.checkedSquare
                        onTapped: boardScreen.onSquareTapped(squareName)
                    }
                }
            }
        }

        Row {
            spacing: 4
            Item { width: 24; height: 1 }
            Row {
                width: grid.width
                Repeater {
                    model: 8
                    Text {
                        required property int index
                        width: grid.width / 8
                        horizontalAlignment: Text.AlignHCenter
                        text: boardScreen.filesRanks().files[index]
                        font.pixelSize: 16
                        color: boardScreen.darkMode ? "#e6e2d8" : "black"
                    }
                }
            }
        }

        Text {
            text: "White: " + Math.floor(boardScreen.whiteTimeMs / 1000) + "s"
            font.pixelSize: 28
            color: boardScreen.darkMode ? "#e6e2d8" : "black"
        }

        Text {
            text: boardScreen.statusText
            font.pixelSize: 24
            color: boardScreen.darkMode ? "#e6e2d8" : "black"
        }

        Button {
            text: "Resign"
            onClicked: boardScreen.backendSender({type: "Resign"})
        }

        Button {
            text: "Back to Home"
            visible: boardScreen.statusText.indexOf("Game over") === 0
            onClicked: boardScreen.navigateTo("HomeScreen.qml")
        }
    }

    // Deliberately no local per-second Timer here. A live-ticking clock means one
    // e-ink partial refresh every second for the whole game (600-900+ for a single
    // rapid game) just to redraw a number nobody's action-gated on -- Qt Quick's own
    // dirty-rect tracking keeps that redraw's *work* cheap, but each one is still a
    // real waveform update with its own latency/ghosting cost we don't control yet
    // (see docs/remarkable-appload-platform-notes.md). Instead the clock only shows
    // time exactly as of the last authoritative BoardState -- it visibly freezes
    // while a player thinks and only moves when a move actually happens, trading
    // a live countdown for zero idle redraws. Revisit if on-device testing shows
    // players actually need the live countdown badly enough to be worth the cost.

    function handleMessage(msg) {
        if (msg.type === "BoardState") {
            boardScreen.fen = msg.fen
            boardScreen.turn = msg.turn
            boardScreen.whiteTimeMs = msg.white_time_ms
            boardScreen.blackTimeMs = msg.black_time_ms
            boardScreen.legalMoves = msg.legal_moves
            boardScreen.lastMove = msg.last_move || null
            boardScreen.inCheck = msg.in_check || false
            boardScreen.yourColor = msg.your_color || "white"
            boardScreen.statusText = ""
        } else if (msg.type === "GameOver") {
            boardScreen.statusText = "Game over: " + msg.result + " (" + msg.reason + ")"
        } else if (msg.type === "MoveRejected") {
            boardScreen.statusText = "Move rejected: " + msg.reason
            boardScreen.selectedSquare = ""
        } else if (msg.type === "Reconnecting") {
            boardScreen.statusText = "Reconnecting..."
        }
    }
}
