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
            return boardStyle.darkMode ? "#a9b3b6" : "#dce5e8"
        if (boardStyle.boardTheme === "green")
            return boardStyle.darkMode ? "#acb39d" : "#dfe5d4"
        if (boardStyle.boardTheme === "mono")
            return boardStyle.darkMode ? "#b5b1a8" : "#e8e6df"
        return boardStyle.darkMode ? "#b0a48e" : "#e8e0d0"
    }

    readonly property color darkSquare: {
        if (boardStyle.boardTheme === "blue")
            return boardStyle.darkMode ? "#687d87" : "#4e6f82"
        if (boardStyle.boardTheme === "green")
            return boardStyle.darkMode ? "#6c7d63" : "#53704c"
        if (boardStyle.boardTheme === "mono")
            return boardStyle.darkMode ? "#74716a" : "#5c5a54"
        return boardStyle.darkMode ? "#776f60" : "#5c4d3a"
    }
    readonly property color checkSquare: boardStyle.darkMode ? "#b95b4f" : "#d1483f"
    readonly property color highlightSquare: boardStyle.darkMode ? "#66946a" : "#4f9d55"
    readonly property color lastMoveSquare: boardStyle.darkMode ? "#6286a3" : "#4f86ad"
    readonly property color premoveSquare: boardStyle.darkMode ? "#a48d43" : "#c9a227"
    readonly property color ink: boardStyle.darkMode ? "#f5f0e5" : "#191817"
}
