import QtQuick 2.9

AppDialog {
    id: dialog
    objectName: "openingExplorerDialog"
    title: "Opening explorer"
    pageByRow: true
    property string database: "masters"
    property var lookup: null
    property bool coolingDown: false
    property bool canTryMove: false
    readonly property var statistics: lookup && lookup.phase === "ready" ? lookup.data : null
    signal databaseSelected(string database)
    signal lookupRequested()
    signal moveSelected(string uci)

    Theme { id: theme; darkMode: dialog.darkMode }

    function games(stats) {
        return stats.white + stats.draws + stats.black
    }

    function gamesLabel(count) {
        return count === 1 ? "1 game" : count.toLocaleString(Qt.locale(), "f", 0) + " games"
    }

    function results(move) {
        var total = games(move)
        if (total === 0) return "No recorded games"
        // Assign leftover percentage points by remainder. Independent rounding
        // can miss 100, and giving every leftover point to draws distorts the split.
        var shares = [move.white, move.draws, move.black].map(function(count) { return count / total * 100 })
        var percent = shares.map(Math.floor)
        var remainderOrder = [0, 1, 2].sort(function(a, b) {
            return (shares[b] - percent[b]) - (shares[a] - percent[a])
        })
        var leftover = 100 - percent[0] - percent[1] - percent[2]
        for (var index = 0; index < leftover; index++) percent[remainderOrder[index]]++
        // Keep the count and results readable at tablet widths. Smaller text
        // reduces legibility, and a details panel adds a tap for every move.
        return gamesLabel(total) + "\n" +
            percent[0] + "% White · " + percent[1] + "% Draw · " + percent[2] + "% Black"
    }

    SegmentedControl {
        objectName: "openingDatabaseSelector"
        width: parent.width
        darkMode: dialog.darkMode
        value: dialog.database
        options: [{id: "masters", label: "Masters"}, {id: "lichess", label: "Lichess rated"}]
        onSelected: (database) => dialog.databaseSelected(database)
    }

    Text {
        objectName: "openingName"
        width: parent.width
        visible: text.length > 0
        text: dialog.statistics && dialog.statistics.opening
            ? dialog.statistics.opening.eco + " · " + dialog.statistics.opening.name : ""
        font.pixelSize: theme.fontBody
        font.bold: true
        color: theme.text
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
    }

    Text {
        objectName: "openingExplorerStatus"
        width: parent.width
        visible: text.length > 0
        text: {
            if (dialog.statistics) {
                var total = dialog.games(dialog.statistics)
                return total === 0 ? "No games found at this position."
                    : dialog.gamesLabel(total) +
                      (dialog.statistics.moves.length === 0 ? " · No continuations found" : "")
            }
            if (dialog.lookup && dialog.lookup.phase === "pending") return "Loading opening statistics…"
            if (dialog.lookup && dialog.lookup.phase === "failed") return dialog.lookup.message
            return dialog.coolingDown ? "Lichess limited opening statistics requests." : ""
        }
        font.pixelSize: theme.fontSmall
        color: dialog.lookup && dialog.lookup.phase === "failed" ? theme.errorText : theme.textMuted
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
    }

    AppButton {
        objectName: "openingExplorerRetry"
        width: parent.width
        visible: !dialog.lookup || dialog.lookup.phase === "failed"
        enabled: !dialog.coolingDown
        text: dialog.coolingDown ? "Retry available shortly" : dialog.lookup ? "Retry" : "Load statistics"
        onClicked: dialog.lookupRequested()
    }

    Repeater {
        model: dialog.statistics ? dialog.statistics.moves : []
        MenuRow {
            required property var modelData
            objectName: "openingMove-" + modelData.uci
            darkMode: dialog.darkMode
            title: modelData.san
            subtitle: dialog.results(modelData)
            wrapSubtitle: true
            marker: dialog.canTryMove ? "Try" : ""
            enabled: dialog.canTryMove
            onClicked: dialog.moveSelected(modelData.uci)
        }
    }

    footer: AppButton {
        objectName: "closeOpeningExplorerButton"
        width: parent.width
        text: "Close"
        onClicked: dialog.dismissed()
    }
}
