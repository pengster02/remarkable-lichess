import QtQuick 2.5

QtObject {
    id: boardStyle
    property bool darkMode: false
    property string boardTheme: "brown"
    property string pieceSet: "cburnett"

    readonly property var boardOptions: [
        {id: "brown", label: "Brown"},
        {id: "blue", label: "Blue"},
        {id: "green", label: "Green"},
        {id: "mono", label: "Mono"}
    ]
    readonly property var pieceOptions: [
        {id: "cburnett", label: "Cburnett"},
        {id: "merida", label: "Merida"},
        {id: "chessnut", label: "Chessnut"}
    ]

    function optionLabel(options, id) {
        for (var i = 0; i < options.length; i++) {
            if (options[i].id === id) return options[i].label
        }
        return options[0].label
    }

    function boardLabel() {
        return boardStyle.optionLabel(boardStyle.boardOptions, boardStyle.boardTheme)
    }

    function pieceLabel() {
        return boardStyle.optionLabel(boardStyle.pieceOptions, boardStyle.pieceSet)
    }

    readonly property color lightSquare: {
        if (boardStyle.boardTheme === "blue")
            return boardStyle.darkMode ? "#68747a" : "#dce5e8"
        if (boardStyle.boardTheme === "green")
            return boardStyle.darkMode ? "#69715f" : "#dfe5d4"
        if (boardStyle.boardTheme === "mono")
            return boardStyle.darkMode ? "#77746d" : "#e8e6df"
        return boardStyle.darkMode ? "#5a5648" : "#e8e0d0"
    }

    readonly property color darkSquare: {
        if (boardStyle.boardTheme === "blue")
            return boardStyle.darkMode ? "#263b46" : "#4e6f82"
        if (boardStyle.boardTheme === "green")
            return boardStyle.darkMode ? "#2c3c28" : "#53704c"
        if (boardStyle.boardTheme === "mono")
            return boardStyle.darkMode ? "#242321" : "#5c5a54"
        return boardStyle.darkMode ? "#211f1a" : "#5c4d3a"
    }
}
