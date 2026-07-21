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
    property bool drawOfferedByOpponent: false
    property bool takebackOfferedByOpponent: false
    // Set from the backend's OpponentGone message. No local countdown against
    // claim_win_in_seconds -- same no-idle-redraw reasoning as the clock below;
    // Lichess's own claim-victory endpoint rejects an early claim regardless.
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
    // Two-tap confirm so a single mistaken tap can't resign the game outright.
    property bool resignArmed: false
    // "username: text" lines, player-room only (see backend_app.rs's chat.room
    // == "player" filter) -- oldest first, matching Lichess's own chat panel.
    property var chatMessages: []
    // SAN per move, sent whole by the backend each BoardState (see
    // game::session::GameSession.move_history) -- only re-rendered when it
    // actually changes, same as everything else here.
    property var moveHistory: []
    // Fixed for the game's lifetime (see game::session::GameSession) -- an AI
    // opponent has no rating, only a name/level, hence the Option on the
    // backend and the "" / null fallback here.
    property string opponentName: ""
    property var opponentRating: null

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

    // Display-order files/ranks, flipped when playing black so the local player's
    // own pieces render at the bottom, matching standard chess-app convention.
    // Written as two plain literals rather than slice().reverse() -- qmllint
    // infers a QVariantList type for these array literals under Qt6's stricter
    // QML type system, which doesn't reliably expose Array.prototype methods.
    function filesRanks() {
        var showBlackAtBottom = (boardScreen.yourColor === "black") !== boardScreen.manualFlip
        if (showBlackAtBottom) {
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
        // Guards an empty/not-yet-loaded fen (default ""): "".split("/") is a
        // single-element [""], so any rank past the first indexes out of bounds
        // here. Confirmed live via the PC emulator -- reproducibly threw
        // "Cannot read property 'length' of undefined" on every square whose
        // rank wasn't the first, every single frame, before a real BoardState
        // ever arrives.
        if (row === undefined) return ""
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

    function onSquareTapped(squareName) {
        // Not a correctness fix (legalMoves is always keyed to whoever's turn it
        // actually is, per the current FEN, so a tap during the opponent's turn
        // could never produce an illegal MakeMove) -- this is the UX gap flagged
        // in docs/chess-ux-gaps-vs-reference-apps.md #5: every reference client
        // disables input and shows whose turn it is rather than letting a player
        // tap around pointlessly waiting for a reply that never comes.
        if (boardScreen.turn !== boardScreen.yourColor) return
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
            var promoOptions = boardScreen.promotionOptionsFor(boardScreen.selectedSquare, squareName)
            if (promoOptions.length > 0) {
                // Don't clear selectedSquare yet -- the promotion popup needs
                // from/to; MakeMove is sent once the user picks a piece below.
                boardScreen.pendingPromotion = {from: boardScreen.selectedSquare, to: squareName, options: promoOptions}
            } else {
                boardScreen.backendSender({type: "MakeMove", from: boardScreen.selectedSquare, to: squareName, promotion: null})
                boardScreen.selectedSquare = ""
            }
        } else {
            boardScreen.selectedSquare = boardScreen.pieceAt(squareName) !== "" ? squareName : ""
        }
    }

    Column {
        anchors.fill: parent
        anchors.topMargin: 72
        spacing: 8

        Text {
            visible: boardScreen.opponentName.length > 0
            text: "vs " + boardScreen.opponentName + (boardScreen.opponentRating !== null ? " (" + boardScreen.opponentRating + ")" : "")
            font.pixelSize: 20
            color: boardScreen.darkMode ? "#e6e2d8" : "black"
        }

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

        Text {
            // Only meaningful once a real game is loaded (turn/yourColor both
            // default to "white" before the first BoardState) -- statusText
            // (game-over/reject/reconnect messages) takes visual precedence
            // above, this is just a steady turn indicator underneath it.
            text: boardScreen.turn === boardScreen.yourColor ? "Your move" : "Waiting for opponent..."
            font.pixelSize: 20
            color: boardScreen.darkMode ? "#e6e2d8" : "black"
        }

        Text {
            text: boardScreen.formattedMoveHistory()
            font.pixelSize: 18
            wrapMode: Text.WordWrap
            width: parent.width
            color: boardScreen.darkMode ? "#e6e2d8" : "black"
        }

        Flow {
            width: parent.width
            spacing: 8

            Button {
                text: boardScreen.drawOfferedByOpponent ? "Accept draw" : "Offer draw"
                onClicked: boardScreen.backendSender({type: "DrawAction", accept: true})
            }
            Button {
                text: "Decline draw"
                visible: boardScreen.drawOfferedByOpponent
                onClicked: boardScreen.backendSender({type: "DrawAction", accept: false})
            }
        }

        Flow {
            width: parent.width
            spacing: 8

            Button {
                text: boardScreen.takebackOfferedByOpponent ? "Accept takeback" : "Offer takeback"
                onClicked: boardScreen.backendSender({type: "TakebackAction", accept: true})
            }
            Button {
                text: "Decline takeback"
                visible: boardScreen.takebackOfferedByOpponent
                onClicked: boardScreen.backendSender({type: "TakebackAction", accept: false})
            }
        }

        Flow {
            width: parent.width
            spacing: 8

            // Lichess itself is the authority on whether an abort is still legal
            // (before either side's first move) -- lastMove is just a cheap,
            // already-available client-side hint to hide the button once it
            // clearly no longer applies, not a full replication of that rule.
            Button {
                text: "Abort"
                visible: boardScreen.lastMove === null
                onClicked: boardScreen.backendSender({type: "Abort"})
            }

            Button {
                text: "Claim victory" + (boardScreen.claimWinInSeconds > 0 ? " (~" + boardScreen.claimWinInSeconds + "s)" : "")
                visible: boardScreen.opponentGone
                onClicked: boardScreen.backendSender({type: "ClaimVictory"})
            }

            Button {
                text: "Claim draw"
                onClicked: boardScreen.backendSender({type: "ClaimDraw"})
            }

            Button {
                text: "Flip board"
                onClicked: boardScreen.manualFlip = !boardScreen.manualFlip
            }

            Button {
                text: boardScreen.resignArmed ? "Tap again to resign" : "Resign"
                onClicked: {
                    if (boardScreen.resignArmed) {
                        boardScreen.backendSender({type: "Resign"})
                        boardScreen.resignArmed = false
                    } else {
                        boardScreen.resignArmed = true
                    }
                }
            }
        }

        Text {
            text: boardScreen.chatMessages.join("\n")
            font.pixelSize: 16
            wrapMode: Text.WordWrap
            width: parent.width
            color: boardScreen.darkMode ? "#e6e2d8" : "black"
        }

        Row {
            spacing: 8
            TextField {
                id: chatInputField
                width: 240
                placeholderText: "Message opponent"
            }
            Button {
                text: "Send"
                onClicked: {
                    if (chatInputField.text.length > 0) {
                        boardScreen.backendSender({type: "SendChat", text: chatInputField.text})
                        chatInputField.text = ""
                    }
                }
            }
        }

        Button {
            text: "Back to Home"
            visible: boardScreen.statusText.indexOf("Game over") === 0
            onClicked: boardScreen.navigateTo("HomeScreen.qml")
        }
    }

    // Modal piece picker for promotion -- see promotionOptionsFor()/onSquareTapped.
    // Blocks board taps underneath while open (modal: true) so a second tap can't
    // land on the board mid-choice.
    Popup {
        id: promotionPopup
        visible: boardScreen.pendingPromotion !== null
        modal: true
        closePolicy: Popup.NoAutoClose
        anchors.centerIn: parent

        Row {
            spacing: 8
            Repeater {
                model: boardScreen.pendingPromotion ? boardScreen.pendingPromotion.options : []
                Rectangle {
                    required property string modelData
                    width: 64
                    height: 64
                    color: boardScreen.darkMode ? "#3a382e" : "#e8e0d0"
                    border.width: 1
                    border.color: boardScreen.darkMode ? "#e6e2d8" : "black"

                    Text {
                        anchors.centerIn: parent
                        text: boardScreen.glyphFor(boardScreen.turn === "white" ? modelData.toUpperCase() : modelData)
                        font.pixelSize: 40
                        color: boardScreen.darkMode ? "#e6e2d8" : "black"
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            boardScreen.backendSender({
                                type: "MakeMove",
                                from: boardScreen.pendingPromotion.from,
                                to: boardScreen.pendingPromotion.to,
                                promotion: modelData
                            })
                            boardScreen.pendingPromotion = null
                            boardScreen.selectedSquare = ""
                        }
                    }
                }
            }
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
            boardScreen.drawOfferedByOpponent = msg.draw_offered_by_opponent || false
            boardScreen.takebackOfferedByOpponent = msg.takeback_offered_by_opponent || false
            boardScreen.moveHistory = msg.move_history || []
            boardScreen.opponentName = msg.opponent_name || ""
            boardScreen.opponentRating = msg.opponent_rating !== undefined ? msg.opponent_rating : null
            boardScreen.resignArmed = false
            boardScreen.statusText = ""
        } else if (msg.type === "GameOver") {
            boardScreen.statusText = "Game over: " + msg.result + " (" + msg.reason + ")"
        } else if (msg.type === "MoveRejected") {
            boardScreen.statusText = "Move rejected: " + msg.reason
            boardScreen.selectedSquare = ""
        } else if (msg.type === "Reconnecting") {
            boardScreen.statusText = "Reconnecting..."
        } else if (msg.type === "OpponentGone") {
            boardScreen.opponentGone = msg.gone
            boardScreen.claimWinInSeconds = msg.claim_win_in_seconds || 0
        } else if (msg.type === "ChatMessage") {
            boardScreen.chatMessages = boardScreen.chatMessages.concat([msg.username + ": " + msg.text])
        } else if (msg.type === "ErrorMsg") {
            // Otherwise a failed draw/takeback/abort/claim (e.g. "Takeback not
            // possible") only ever reached main.qml's console.warn -- invisible
            // to an actual player on-device.
            boardScreen.statusText = msg.message
        }
    }
}
