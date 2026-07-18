import QtQuick 2.5
import QtQuick.Controls 2.5

Rectangle {
    id: boardScreen
    anchors.fill: parent
    color: "white"
    property var backendSender
    property var navigateTo

    property string fen: ""
    property string turn: "white"
    property int whiteTimeMs: 0
    property int blackTimeMs: 0
    property var legalMoves: []
    property string selectedSquare: ""
    property string statusText: ""

    function filesRanks() {
        var files = ["a","b","c","d","e","f","g","h"]
        var ranks = ["8","7","6","5","4","3","2","1"]
        return {files: files, ranks: ranks}
    }

    function pieceAt(squareName) {
        // Minimal FEN board decode: walk the piece-placement field only.
        var placement = fen.split(" ")[0]
        var rows = placement.split("/")
        var fr = filesRanks()
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
        for (var i = 0; i < legalMoves.length; i++) {
            if (legalMoves[i].from === square) out.push(legalMoves[i].to)
        }
        return out
    }

    function onSquareTapped(squareName) {
        if (selectedSquare === "") {
            if (pieceAt(squareName) !== "") selectedSquare = squareName
            return
        }
        if (selectedSquare === squareName) {
            selectedSquare = ""
            return
        }
        var dests = destinationsFrom(selectedSquare)
        if (dests.indexOf(squareName) !== -1) {
            var promo = null
            for (var i = 0; i < legalMoves.length; i++) {
                if (legalMoves[i].from === selectedSquare && legalMoves[i].to === squareName && legalMoves[i].promotion) {
                    if (promo === null) {
                        promo = legalMoves[i].promotion
                    }
                    if (legalMoves[i].promotion === "q") {
                        promo = legalMoves[i].promotion
                        break
                    }
                }
            }
            backendSender({type: "MakeMove", from: selectedSquare, to: squareName, promotion: promo})
            selectedSquare = ""
        } else {
            selectedSquare = pieceAt(squareName) !== "" ? squareName : ""
        }
    }

    Column {
        anchors.fill: parent
        spacing: 8

        Text {
            text: "Black: " + Math.floor(blackTimeMs / 1000) + "s"
            font.pixelSize: 28
        }

        Grid {
            id: grid
            columns: 8
            rows: 8
            width: Math.min(boardScreen.width, boardScreen.height - 160)
            height: width

            Repeater {
                model: 64
                BoardSquare {
                    width: grid.width / 8
                    height: grid.height / 8
                    property int fileIdx: index % 8
                    property int rankIdx: Math.floor(index / 8)
                    squareName: filesRanks().files[fileIdx] + filesRanks().ranks[rankIdx]
                    isLight: (fileIdx + rankIdx) % 2 === 0
                    pieceGlyph: glyphFor(pieceAt(squareName))
                    isHighlighted: selectedSquare === squareName || destinationsFrom(selectedSquare).indexOf(squareName) !== -1
                    onTapped: onSquareTapped(squareName)
                }
            }
        }

        Text {
            text: "White: " + Math.floor(whiteTimeMs / 1000) + "s"
            font.pixelSize: 28
        }

        Text {
            text: statusText
            font.pixelSize: 24
        }

        Button {
            text: "Resign"
            onClicked: backendSender({type: "Resign"})
        }

        Button {
            text: "Back to Home"
            visible: statusText.indexOf("Game over") === 0
            onClicked: navigateTo("HomeScreen.qml")
        }
    }

    Timer {
        interval: 1000
        running: fen !== "" && statusText.indexOf("Game over") !== 0
        repeat: true
        onTriggered: {
            if (turn === "white") {
                whiteTimeMs = Math.max(0, whiteTimeMs - 1000)
            } else {
                blackTimeMs = Math.max(0, blackTimeMs - 1000)
            }
        }
    }

    function handleMessage(msg) {
        if (msg.type === "BoardState") {
            fen = msg.fen
            turn = msg.turn
            whiteTimeMs = msg.white_time_ms
            blackTimeMs = msg.black_time_ms
            legalMoves = msg.legal_moves
            statusText = ""
        } else if (msg.type === "GameOver") {
            statusText = "Game over: " + msg.result + " (" + msg.reason + ")"
        } else if (msg.type === "MoveRejected") {
            statusText = "Move rejected: " + msg.reason
            selectedSquare = ""
        } else if (msg.type === "Reconnecting") {
            statusText = "Reconnecting..."
        }
    }
}
