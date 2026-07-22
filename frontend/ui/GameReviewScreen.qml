import QtQuick 2.5
import QtQuick.Controls 2.5
import net.asivery.ApploadUtils

// Read-only replay of a finished game's move list, opened from
// GameHistoryScreen (see docs/superpowers/specs/2026-07-21-game-review-move-navigation-design.md).
// `moves`/`fens` arrive pre-computed from the backend's GameMoves reply
// (main.qml hands them in on load, same pattern as darkMode/username) -- this
// screen does no chess logic at all, just indexes into `fens`.
Rectangle {
    id: gameReviewScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: gameReviewScreen.darkMode }
    property var backendSender
    property var navigateTo
    property bool darkMode: false

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
    // Same flip-for-black-at-bottom convenience as BoardScreen's own manualFlip,
    // just with no yourColor to XOR against here -- a finished game has no
    // "your" side baked into GameMoves, so this is the only orientation control.
    property bool manualFlip: false

    function currentFen() {
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

    property var currentPieceMap: gameReviewScreen.buildPieceMap(gameReviewScreen.currentFen())
    property var previousPieceMap: gameReviewScreen.currentIndex > 0
        ? gameReviewScreen.buildPieceMap(gameReviewScreen.fens[gameReviewScreen.currentIndex - 1])
        : ({})

    // Kept parameterized on `fen` (not hardcoded to currentFen()) so this
    // stays a general-purpose lookup, but the two fens actually in play here
    // (current and previous) go through the cached maps above instead of
    // rebuilding one from scratch on every call.
    function pieceAt(fen, squareName) {
        if (fen === gameReviewScreen.currentFen()) return gameReviewScreen.currentPieceMap[squareName] || ""
        if (gameReviewScreen.currentIndex > 0 && fen === gameReviewScreen.fens[gameReviewScreen.currentIndex - 1]) {
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
        if (gameReviewScreen.currentIndex === 0) return []
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
    // filesRanks() itself is cheap, but it's read by all 64 squares plus 16
    // rank/file labels every redraw, each call allocating two fresh arrays --
    // same "compute once, index many" reasoning as the piece maps above.
    property var fr: gameReviewScreen.filesRanks()

    // Safe, bounds-checked lookup into `analysis`/`clockMs` -- both may be
    // shorter than `moves` or empty (see their own property comments above),
    // so every read goes through here rather than direct indexing.
    function analysisAt(plyIndex) {
        return plyIndex >= 0 && plyIndex < gameReviewScreen.analysis.length ? gameReviewScreen.analysis[plyIndex] : null
    }

    function clockAt(plyIndex) {
        return plyIndex >= 0 && plyIndex < gameReviewScreen.clockMs.length ? gameReviewScreen.clockMs[plyIndex] : null
    }

    // Same mm:ss format as BoardScreen's own formatClock -- this is the
    // remaining time *after* that ply, not a live countdown, so there's no
    // seconds-vs-centiseconds subtlety to handle beyond the ms conversion
    // backend_app.rs already did.
    function formatClock(ms) {
        var totalSeconds = Math.floor(ms / 1000)
        var minutes = Math.floor(totalSeconds / 60)
        var seconds = totalSeconds % 60
        return minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    }

    // Classic PGN annotation glyphs -- the exact suffix Lichess's own move
    // list and every PGN viewer appends to a flagged move, so "Qh5??" reads
    // the same way here as everywhere else in chess.
    function judgmentSuffix(judgment) {
        if (judgment === "Blunder") return "??"
        if (judgment === "Mistake") return "?"
        if (judgment === "Inaccuracy") return "?!"
        return ""
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

    // "1. e4 e5  2. Nf3 Nc6" tokens, one per ply, each carrying its own fens
    // index so a tap can jump straight there -- unlike BoardScreen's own
    // formattedMoveHistory (one joined, unclickable string), every ply here
    // needs to be an individually tappable target. Also folds in this ply's
    // own clock/judgment when available, both purely additive to the SAN
    // itself (e.g. "5. Qh5?? (3:12)") rather than separate columns, since a
    // Flow-of-tokens layout has no fixed columns to align to.
    function moveTokens() {
        var out = []
        for (var i = 0; i < gameReviewScreen.moves.length; i++) {
            var entry = gameReviewScreen.analysisAt(i)
            var judgment = entry && entry.judgment ? entry.judgment : null
            var clock = gameReviewScreen.clockAt(i)
            var label = (i % 2 === 0 ? (i / 2 + 1) + ". " : "") + gameReviewScreen.moves[i] + gameReviewScreen.judgmentSuffix(judgment)
            if (clock !== null) label += " (" + gameReviewScreen.formatClock(clock) + ")"
            out.push({
                label: label,
                fenIndex: i + 1,
                judgment: judgment,
                judgmentComment: entry ? entry.judgment_comment : null
            })
        }
        return out
    }

    // Same labeling/coloring as GameHistoryScreen's own resultLabel/resultColor
    // -- duplicated rather than shared since there's no common QML module for
    // cross-screen helpers here (every screen already inlines its own small
    // formatting functions, e.g. BoardScreen's formatClock).
    function resultLabel(result) {
        if (result === "win") return "Win"
        if (result === "loss") return "Loss"
        if (result === "draw") return "Draw"
        return result.charAt(0).toUpperCase() + result.slice(1)
    }

    function resultColor(result) {
        if (result === "win") return theme.winText
        if (result === "loss") return theme.lossText
        return theme.drawText
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
        spacing: theme.spacingSmall

        Row {
            spacing: theme.spacingSmall
            visible: gameReviewScreen.game !== null
            Text {
                text: gameReviewScreen.game ? gameReviewScreen.resultLabel(gameReviewScreen.game.result) : ""
                font.pixelSize: theme.fontBody
                font.bold: true
                color: gameReviewScreen.game ? gameReviewScreen.resultColor(gameReviewScreen.game.result) : theme.text
            }
            // Your own rating change from this one game (rated games only).
            Text {
                visible: gameReviewScreen.game !== null && gameReviewScreen.game.rating_diff !== null && gameReviewScreen.game.rating_diff !== undefined
                text: gameReviewScreen.game && gameReviewScreen.game.rating_diff > 0
                    ? ("+" + gameReviewScreen.game.rating_diff)
                    : ("" + (gameReviewScreen.game ? gameReviewScreen.game.rating_diff : ""))
                font.pixelSize: theme.fontBody
                color: gameReviewScreen.game && gameReviewScreen.game.rating_diff > 0 ? theme.winText : theme.lossText
            }
            Text {
                text: gameReviewScreen.game
                    ? "vs " + (gameReviewScreen.game.opponent_name || "Opponent") +
                      (gameReviewScreen.game.opponent_rating ? " (" + gameReviewScreen.game.opponent_rating + ")" : "")
                    : ""
                font.pixelSize: theme.fontBody
                color: theme.text
            }
        }

        Text {
            visible: gameReviewScreen.game !== null
            text: gameReviewScreen.game
                ? (gameReviewScreen.game.rated ? "Rated" : "Casual") +
                  (gameReviewScreen.game.speed ? " " + gameReviewScreen.game.speed : "") +
                  (gameReviewScreen.game.termination ? " -- " + gameReviewScreen.game.termination : "") +
                  (gameReviewScreen.game.opening_name ? " -- " + gameReviewScreen.game.opening_name : "") +
                  (gameReviewScreen.game.created_at_ms ? " -- " + new Date(gameReviewScreen.game.created_at_ms).toLocaleDateString() : "")
                : ""
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
            visible: gameReviewScreen.game !== null && gameReviewScreen.game.your_analysis
            text: gameReviewScreen.game && gameReviewScreen.game.your_analysis
                ? "Your accuracy: " +
                  (gameReviewScreen.game.your_analysis.accuracy !== null && gameReviewScreen.game.your_analysis.accuracy !== undefined
                      ? gameReviewScreen.game.your_analysis.accuracy + "%"
                      : "n/a") +
                  " -- " + gameReviewScreen.game.your_analysis.inaccuracies + " inaccuracies, " +
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
                text: "Move " + gameReviewScreen.currentIndex + " of " + Math.max(0, gameReviewScreen.fens.length - 1)
                font.pixelSize: theme.fontBody
                color: theme.text
            }
            // Engine eval for the position on the board right now -- from
            // analysis[currentIndex - 1], the ply that produced fens[currentIndex]
            // (analysis has no entry for the starting position, same off-by-one
            // as fens/moves themselves). Empty for an unanalyzed game or before
            // any move has been made yet.
            Text {
                text: gameReviewScreen.evalLabel(gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1))
                font.pixelSize: theme.fontBody
                font.bold: true
                color: theme.textMuted
            }
        }

        // The comment for whichever move is currently displayed, when that
        // move was actually flagged -- e.g. "Blunder. Nxg6 was best.", the
        // exact caption Lichess's own analysis board shows.
        Text {
            visible: gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1) &&
                     gameReviewScreen.analysisAt(gameReviewScreen.currentIndex - 1).judgment_comment
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
                        text: gameReviewScreen.fr.ranks[index]
                        font.pixelSize: theme.fontSmall
                        color: theme.text
                    }
                }
            }

            Grid {
                id: grid
                columns: 8
                rows: 8
                // Capped at half the screen height (not "height - N" the way
                // BoardScreen sizes its own grid) -- boardArea only wraps the
                // grid/nav controls here, not the whole screen, so the move
                // list below always gets its own share of the remaining space
                // regardless of how tall this device's screen is.
                width: Math.min(gameReviewScreen.width - rankLabels.width - theme.spacingXs, gameReviewScreen.height * 0.5)
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
                        pieceCode: gameReviewScreen.pieceCodeFor(gameReviewScreen.pieceAt(gameReviewScreen.currentFen(), squareName))
                        // No isHighlighted/isCheckSquare here -- read-only review
                        // has no selection state and no legality to flag, only
                        // the diff-derived last-move squares above.
                        isLastMove: gameReviewScreen.lastMoveSquaresCached.indexOf(squareName) !== -1
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
                        text: gameReviewScreen.fr.files[index]
                        font.pixelSize: theme.fontSmall
                        color: theme.text
                    }
                }
            }
        }

        Flow {
            width: parent.width
            spacing: theme.spacingSmall

            Button {
                text: "|< First"
                enabled: gameReviewScreen.currentIndex > 0
                onClicked: gameReviewScreen.goFirst()
            }
            Button {
                text: "< Prev"
                enabled: gameReviewScreen.currentIndex > 0
                onClicked: gameReviewScreen.goPrev()
            }
            Button {
                text: "Next >"
                enabled: gameReviewScreen.currentIndex < gameReviewScreen.fens.length - 1
                onClicked: gameReviewScreen.goNext()
            }
            Button {
                text: "Last >|"
                enabled: gameReviewScreen.currentIndex < gameReviewScreen.fens.length - 1
                onClicked: gameReviewScreen.goLast()
            }
            Button {
                text: "Flip board"
                onClicked: gameReviewScreen.manualFlip = !gameReviewScreen.manualFlip
            }
        }
    }

    // Root-level sibling anchored to `grid`'s own bounds -- same reasoning as
    // BoardScreen.qml's own copy of this: placing it inside Grid/Row (both
    // positioners) would have it auto-positioned as an extra layout cell
    // instead of treated as a plain overlay. Same transient-highlight
    // (here: last-move diff) reasoning as BoardScreen's board -- speed beats
    // fidelity for it. See docs/remarkable-appload-platform-notes.md §2.
    DisplayMethodArea {
        anchors.fill: grid
        displayMethod: DisplayMethodArea.Fast
    }

    Button {
        id: backButton
        // Same fixed, full-width bottom "nav bar" treatment as every other
        // screen's back action (see GameHistoryScreen/SettingsScreen/
        // SeekScreen/BoardScreen) instead of this screen's own one-off
        // bottom-left placement.
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: theme.pageSideMargin
        text: "Back to Game History"
        onClicked: gameReviewScreen.navigateTo("GameHistoryScreen.qml")
    }

    Flickable {
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
        boundsBehavior: Flickable.StopAtBounds
        clip: true
        contentWidth: width
        contentHeight: moveFlow.height

        Flow {
            id: moveFlow
            width: parent.width
            spacing: theme.spacingSmall
            Repeater {
                model: gameReviewScreen.moveTokens()
                Text {
                    required property var modelData
                    text: modelData.label
                    font.pixelSize: theme.fontSmall
                    font.bold: modelData.fenIndex === gameReviewScreen.currentIndex
                    // The current ply always wins the accent color even over a
                    // judgment color -- "where am I" outranks "was this move
                    // bad" once you're actually looking at it.
                    color: modelData.fenIndex === gameReviewScreen.currentIndex
                        ? theme.accentBackground
                        : gameReviewScreen.judgmentColor(modelData.judgment)
                    MouseArea {
                        anchors.fill: parent
                        onClicked: gameReviewScreen.currentIndex = modelData.fenIndex
                    }
                }
            }
        }
    }
}
