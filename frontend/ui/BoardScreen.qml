import QtQuick 2.5
import QtQuick.Controls 2.5
import net.asivery.ApploadUtils

Rectangle {
    id: boardScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: boardScreen.darkMode }
    property var backendSender
    property var navigateTo
    property bool darkMode: false

    property string fen: ""
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
    // Forces a black frame over the board on every move (see the Timer and
    // the Rectangle over the Grid) -- Content alone still ghosted on
    // low-contrast transitions (a black piece leaving a dark square).
    property bool flashBoard: false
    Timer {
        id: boardFlashTimer
        interval: 90
        onTriggered: boardScreen.flashBoard = false
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
    // Fixed for the game's lifetime (see game::session::GameSession) -- an AI
    // opponent has no rating, only a name/level, hence the Option on the
    // backend and the "" / null fallback here.
    property string opponentName: ""
    property var opponentRating: null
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

    // Single choke point for "a move is fully resolved (including any
    // promotion piece) and ready to send" -- either sends it immediately, or
    // (when moveConfirmation is on) parks it in pendingMoveConfirmation for
    // confirmPendingMove/cancelPendingMove to resolve. Every MakeMove send
    // in this file goes through here rather than calling backendSender
    // directly, so the confirmation gate can't accidentally be bypassed by
    // one call site while another respects it.
    function requestMove(from, to, promotion) {
        if (boardScreen.moveConfirmation) {
            boardScreen.pendingMoveConfirmation = {from: from, to: to, promotion: promotion}
        } else {
            boardScreen.backendSender({type: "MakeMove", from: from, to: to, promotion: promotion})
            boardScreen.selectedSquare = ""
        }
    }

    function confirmPendingMove() {
        if (boardScreen.pendingMoveConfirmation === null) return
        boardScreen.backendSender({
            type: "MakeMove",
            from: boardScreen.pendingMoveConfirmation.from,
            to: boardScreen.pendingMoveConfirmation.to,
            promotion: boardScreen.pendingMoveConfirmation.promotion
        })
        boardScreen.pendingMoveConfirmation = null
        boardScreen.selectedSquare = ""
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
    // game's does. Visual only, no sound and no local ticking Timer (see the
    // no-Timer comment below) -- this just runs inside a redraw a real
    // BoardState update was already causing, zero extra cost. Returns false
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

    // Destination square only -- highlighting the origin square too read as an
    // unwanted "afterglow" trailing every piece that moved, not a useful cue.
    function isLastMoveSquare(sq) {
        return boardScreen.lastMove !== null && sq === boardScreen.lastMove[1]
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
    // filesRanks() itself is cheap, but it's read by all 64 squares plus 16
    // rank/file labels every redraw, each call allocating two fresh arrays --
    // same "compute once, index many" reasoning as selectedDestinations above.
    property var fr: boardScreen.filesRanks()
    // Full FEN decode, done once per redraw here rather than once per square
    // (64 full string walks otherwise, since pieceAt() used to re-parse the
    // whole placement field on every single call -- checkedKingSquare() alone
    // was already calling it 64 times by itself).
    property var pieceMap: boardScreen.buildPieceMap(boardScreen.fen)

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
        return (boardScreen.turn === "white" ? "w" : "b") + letter.toUpperCase()
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
        // A tap on the board can't do anything useful while a move is
        // already awaiting explicit Confirm/Cancel -- those buttons (or the
        // popup below) are the only way forward from here.
        if (boardScreen.pendingMoveConfirmation !== null) return
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
            if (promoOptions.length > 0 && boardScreen.autoQueenPromotion && promoOptions.indexOf("q") !== -1) {
                boardScreen.requestMove(boardScreen.selectedSquare, squareName, "q")
            } else if (promoOptions.length > 0) {
                // Don't clear selectedSquare yet -- the promotion popup needs
                // from/to; requestMove (which itself may just park this in
                // pendingMoveConfirmation rather than send it) runs once the
                // user picks a piece below.
                boardScreen.pendingPromotion = {from: boardScreen.selectedSquare, to: squareName, options: promoOptions}
            } else {
                boardScreen.requestMove(boardScreen.selectedSquare, squareName, null)
            }
        } else {
            boardScreen.selectedSquare = boardScreen.pieceAt(squareName) !== "" ? squareName : ""
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
            width: parent.width
            darkMode: boardScreen.darkMode
            playerName: boardScreen.nameFor(boardScreen.topColor)
            rating: boardScreen.ratingFor(boardScreen.topColor)
            clockMs: boardScreen.clockFor(boardScreen.topColor)
            showClock: boardScreen.initialClockMs !== null
            active: boardScreen.turn === boardScreen.topColor
            lowTime: boardScreen.isLowTime(boardScreen.clockFor(boardScreen.topColor), boardScreen.initialClockMs)
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

            // Wraps the Grid (DisplayMethodArea must be a parent/sibling, not
            // anchored from elsewhere). Content, not Fast: Fast left visible
            // ghosting after a move.
            DisplayMethodArea {
                displayMethod: DisplayMethodArea.Content
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
                            isLastMove: boardScreen.isLastMoveSquare(squareName)
                            isCheckSquare: squareName === boardScreen.checkedSquare
                            onTapped: boardScreen.onSquareTapped(squareName)
                        }
                    }
                }

                // Forces the black-flash ghosting fix (see flashBoard's own
                // comment) -- sits on top of the Grid, briefly opaque black.
                Rectangle {
                    anchors.fill: parent
                    color: "black"
                    visible: boardScreen.flashBoard
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
            clockMs: boardScreen.clockFor(boardScreen.bottomColor)
            showClock: boardScreen.initialClockMs !== null
            active: boardScreen.turn === boardScreen.bottomColor
            lowTime: boardScreen.isLowTime(boardScreen.clockFor(boardScreen.bottomColor), boardScreen.initialClockMs)
        }
    }

    Flickable {
        // Everything below the chess frame scrolls -- so the draw/takeback/
        // resign controls, move list, and chat are all always reachable no
        // matter how many of the conditional rows (offers, claim victory,
        // confirm) happen to be visible at once. The board and player bars
        // above never move.
        anchors.top: boardColumn.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: backButton.top
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.spacingSmall
        anchors.bottomMargin: theme.spacingSmall
        contentWidth: width
        contentHeight: actionsColumn.height
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
        id: actionsColumn
        width: parent.width
        spacing: theme.spacingXs

        Text {
            visible: boardScreen.statusText.length > 0
            text: boardScreen.statusText
            font.pixelSize: theme.fontLarge
            font.bold: true
            wrapMode: Text.WordWrap
            width: parent.width
            color: theme.text

            DisplayMethodArea {
                anchors.fill: parent
                displayMethod: DisplayMethodArea.Content
            }
        }

        Text {
            // Only meaningful once a real game is loaded (turn/yourColor both
            // default to "white" before the first BoardState) -- statusText
            // (game-over/reject/reconnect messages) takes visual precedence
            // above, this is just a steady turn indicator underneath it.
            text: boardScreen.turn === boardScreen.yourColor ? "Your move" : "Waiting for opponent..."
            font.pixelSize: theme.fontBody
            color: theme.text

            DisplayMethodArea {
                anchors.fill: parent
                displayMethod: DisplayMethodArea.Content
            }
        }

        Text {
            text: boardScreen.formattedMoveHistory()
            font.pixelSize: theme.fontSmall
            wrapMode: Text.WordWrap
            width: parent.width
            color: theme.text
        }

        Flow {
            width: parent.width
            spacing: theme.spacingSmall

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
            spacing: theme.spacingSmall

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
            spacing: theme.spacingSmall

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
            font.pixelSize: theme.fontSmall
            wrapMode: Text.WordWrap
            width: parent.width
            color: theme.text
        }

        Row {
            spacing: theme.spacingSmall
            TextField {
                id: chatInputField
                width: theme.textFieldWidthMedium
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

        }
    }

    Button {
        id: backButton
        // Fixed, full-width bottom "nav bar" treatment, same as every other
        // screen in this pass -- was just the last item inside the Column
        // above, i.e. wherever the rest of that Column's content happened to
        // end (variable, since most of what's above it is itself
        // conditionally visible -- draw/takeback offers, chat history length,
        // etc.).
        //
        // Always available, not just after Game Over -- an in-progress game
        // keeps running/resumable server-side (see HomeScreen's "Resume"
        // button, backed by handle_resume_game), so there's no reason
        // leaving mid-game should require ending or waiting out the game.
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        text: "Back to Home"
        onClicked: boardScreen.navigateTo("HomeScreen.qml")
    }

    // Modal piece picker for promotion -- see promotionOptionsFor()/onSquareTapped.
    // Blocks board taps underneath while open (modal: true) so a second tap can't
    // land on the board mid-choice.
    Popup {
        id: promotionPopup
        visible: boardScreen.pendingPromotion !== null
        modal: true
        // `modal: true` alone draws a translucent full-screen dim overlay
        // (Overlay.modal) on open *and* close, and the Basic style's default
        // enter/exit transitions fade that dim's opacity across several
        // frames -- each is real full-screen e-ink damage for what should
        // just be a small centered popup. `dim: false` drops the overlay
        // (modal input-blocking itself is unaffected -- that's a separate
        // mechanism from the dim visual); `enter: null`/`exit: null` drop the
        // fade so the popup itself appears/disappears in one step instead of
        // animating across frames.
        dim: false
        enter: null
        exit: null
        closePolicy: Popup.NoAutoClose
        anchors.centerIn: parent

        Row {
            spacing: theme.spacingSmall
            Repeater {
                model: boardScreen.pendingPromotion ? boardScreen.pendingPromotion.options : []
                Rectangle {
                    required property string modelData
                    width: 128
                    height: 128
                    color: theme.cardBackground
                    border.width: 1
                    border.color: theme.text

                    Image {
                        anchors.centerIn: parent
                        width: parent.width * 0.82
                        height: parent.height * 0.82
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        source: "../assets/pieces/" + boardScreen.promotionPieceCode(modelData) + ".png"
                        sourceSize.width: width
                        sourceSize.height: height
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            var from = boardScreen.pendingPromotion.from
                            var to = boardScreen.pendingPromotion.to
                            boardScreen.pendingPromotion = null
                            boardScreen.requestMove(from, to, modelData)
                        }
                    }
                }
            }
        }
    }

    // Confirm/Cancel gate for moveConfirmation (see requestMove) -- same
    // modal styling/blocking posture as the promotion popup above, shown
    // *instead* of sending MakeMove once a legal destination (and promotion
    // piece, if any) has already been resolved.
    Popup {
        id: moveConfirmPopup
        visible: boardScreen.pendingMoveConfirmation !== null
        modal: true
        // Same dim-overlay/fade-transition e-ink cost as the promotion popup
        // above, same fix.
        dim: false
        enter: null
        exit: null
        closePolicy: Popup.NoAutoClose
        anchors.centerIn: parent

        Rectangle {
            width: confirmColumn.width + theme.spacingLarge
            height: confirmColumn.height + theme.spacingLarge
            color: theme.cardBackground
            border.width: 1
            border.color: theme.text

            Column {
                id: confirmColumn
                anchors.centerIn: parent
                spacing: theme.spacingMedium

                Text {
                    text: boardScreen.pendingMoveConfirmation
                        ? "Confirm move " + boardScreen.pendingMoveConfirmation.from + " " + boardScreen.pendingMoveConfirmation.to +
                          (boardScreen.pendingMoveConfirmation.promotion ? "=" + boardScreen.pendingMoveConfirmation.promotion.toUpperCase() : "") + "?"
                        : ""
                    font.pixelSize: theme.fontBody
                    color: theme.text
                }

                Row {
                    spacing: theme.spacingSmall
                    Button {
                        text: "Confirm"
                        onClicked: boardScreen.confirmPendingMove()
                    }
                    Button {
                        text: "Cancel"
                        onClicked: boardScreen.cancelPendingMove()
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
            if (boardScreen.fen !== "" && boardScreen.fen !== msg.fen) {
                boardScreen.flashBoard = true
                boardFlashTimer.restart()
            }
            boardScreen.fen = msg.fen
            boardScreen.turn = msg.turn
            boardScreen.whiteTimeMs = msg.white_time_ms
            boardScreen.blackTimeMs = msg.black_time_ms
            boardScreen.initialClockMs = msg.initial_clock_ms !== undefined ? msg.initial_clock_ms : null
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
            // A RatingDiff for a previous game that never got consumed (its
            // own GameOver never arrived on this screen, e.g. after a
            // Back-to-Home-and-Resume round trip) must not bleed into this
            // new game's eventual GameOver text.
            boardScreen.pendingRatingDiffText = ""
            boardScreen.statusText = ""
        } else if (msg.type === "GameOver") {
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
            } else if (msg.result === "white" || msg.result === "black") {
                outcome = msg.result === boardScreen.yourColor ? "You won" : "You lost"
            } else {
                outcome = msg.result.charAt(0).toUpperCase() + msg.result.slice(1)
            }
            boardScreen.statusText = "Game over: " + outcome + " (" + msg.reason + ")"
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
        } else if (msg.type === "MoveRejected") {
            boardScreen.statusText = "Move rejected: " + msg.reason
            boardScreen.selectedSquare = ""
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
        } else if (msg.type === "ErrorMsg") {
            // Otherwise a failed draw/takeback/abort/claim (e.g. "Takeback not
            // possible") only ever reached main.qml's console.warn -- invisible
            // to an actual player on-device.
            boardScreen.statusText = msg.message
        }
    }
}
