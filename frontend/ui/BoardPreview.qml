import QtQuick 2.5

Item {
    id: preview
    property bool darkMode: false
    property string boardTheme: "brown"
    property string pieceSet: "cburnett"

    BoardStyle {
        id: boardStyle
        darkMode: preview.darkMode
        boardTheme: preview.boardTheme
        pieceSet: preview.pieceSet
    }

    function pieceCodeAt(index) {
        var file = index % 8
        var rank = Math.floor(index / 8)
        var backRank = ["R", "N", "B", "Q", "K", "B", "N", "R"]
        if (rank === 0) return "b" + backRank[file]
        if (rank === 1) return "bP"
        if (rank === 6) return "wP"
        if (rank === 7) return "w" + backRank[file]
        return ""
    }

    Grid {
        anchors.fill: parent
        columns: 8
        rows: 8

        Repeater {
            model: 64

            BoardSquare {
                required property int index
                width: preview.width / 8
                height: preview.height / 8
                isLight: (index % 8 + Math.floor(index / 8)) % 2 === 0
                darkMode: preview.darkMode
                lightSquareColor: boardStyle.lightSquare
                darkSquareColor: boardStyle.darkSquare
                pieceSet: preview.pieceSet
                pieceCode: preview.pieceCodeAt(index)
            }
        }
    }
}
