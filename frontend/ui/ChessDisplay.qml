import QtQuick 2.5

QtObject {
    function boardLeft(availableWidth, boardWidth, coordinateInset) {
        // Center when the gutter fits. Fixed symmetric gutters shrink narrow boards, and left alignment wastes wide space.
        return Math.max(coordinateInset, (availableWidth - boardWidth) / 2)
    }

    function humanizeIdentifier(value) {
        if (value === null || value === undefined || String(value).length === 0) return "Unknown"
        var text = String(value)
        if (text.indexOf(" ") !== -1) return text
        text = text.replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/[_-]+/g, " ")
        return text.charAt(0).toUpperCase() + text.slice(1)
    }

    function resultLabel(result) {
        if (result === "win") return "Win"
        if (result === "loss") return "Loss"
        if (result === "draw") return "Draw"
        return terminationLabel(result)
    }

    function terminationLabel(status) {
        if (status === "created") return "Game created"
        if (status === "started") return "In progress"
        if (status === "aborted") return "Aborted"
        if (status === "mate") return "Checkmate"
        if (status === "resign") return "Resignation"
        if (status === "stalemate") return "Stalemate"
        if (status === "timeout") return "Disconnection"
        if (status === "draw") return "Draw"
        if (status === "outoftime") return "Time forfeit"
        if (status === "cheat") return "Cheat detected"
        if (status === "noStart") return "First move deadline missed"
        if (status === "unknownFinish") return "Unknown finish"
        if (status === "insufficientMaterialClaim") return "Insufficient material"
        if (status === "variantEnd") return "Variant ending"
        return humanizeIdentifier(status)
    }

    function speedLabel(speed) {
        if (speed === "ultraBullet") return "UltraBullet"
        if (speed === "bullet") return "Bullet"
        if (speed === "blitz") return "Blitz"
        if (speed === "rapid") return "Rapid"
        if (speed === "classical") return "Classical"
        if (speed === "correspondence") return "Correspondence"
        return variantLabel(speed) || humanizeIdentifier(speed)
    }

    function variantLabel(variant) {
        if (!variant || variant === "standard") return ""
        if (variant === "chess960") return "Chess960"
        if (variant === "kingOfTheHill") return "King of the Hill"
        if (variant === "racingKings") return "Racing Kings"
        if (variant === "threeCheck") return "Three-check"
        if (variant === "fromPosition") return "Custom position"
        return humanizeIdentifier(variant)
    }

    function formatClock(ms) {
        var totalSeconds = Math.max(0, Math.floor(ms / 1000))
        var hours = Math.floor(totalSeconds / 3600)
        var minutes = Math.floor((totalSeconds % 3600) / 60)
        var seconds = totalSeconds % 60
        var paddedSeconds = (seconds < 10 ? "0" : "") + seconds
        if (hours > 0) {
            return hours + ":" + (minutes < 10 ? "0" : "") + minutes + ":" + paddedSeconds
        }
        return minutes + ":" + paddedSeconds
    }

    function judgmentSuffix(judgment) {
        if (judgment === "Blunder") return "??"
        if (judgment === "Mistake") return "?"
        if (judgment === "Inaccuracy") return "?!"
        return ""
    }

    function moveEntry(moves, clocks, analysis, plyIndex) {
        if (!moves || plyIndex < 0 || plyIndex >= moves.length) return null
        var entry = analysis && plyIndex < analysis.length ? analysis[plyIndex] : null
        var judgment = entry && entry.judgment ? entry.judgment : null
        var clock = clocks && plyIndex < clocks.length ? clocks[plyIndex] : null
        return {
            san: String(moves[plyIndex]) + judgmentSuffix(judgment),
            fenIndex: plyIndex + 1,
            clockLabel: clock === null || clock === undefined ? "" : formatClock(clock),
            judgment: judgment,
            judgmentComment: entry ? entry.judgment_comment : null
        }
    }

    function moveListStart(initialFen) {
        // The starting snapshot already carries both values. Fixed numbering
        // mislabels custom games, and sending a second copy can drift from replay.
        var fields = String(initialFen || "").trim().split(/\s+/)
        return { number: parseInt(fields[5], 10) || 1, blackOffset: fields[1] === "b" ? 1 : 0 }
    }

    function moveRowIndex(fenIndex, initialFen) {
        return Math.floor((fenIndex - 1 + moveListStart(initialFen).blackOffset) / 2)
    }

    function moveRows(moves, clocks, analysis, initialFen) {
        var rows = []
        if (!moves || moves.length === 0) return rows
        var start = moveListStart(initialFen)
        for (var plyIndex = -start.blackOffset; plyIndex < moves.length; plyIndex += 2) {
            rows.push({
                number: start.number + rows.length,
                white: moveEntry(moves, clocks, analysis, plyIndex),
                black: moveEntry(moves, clocks, analysis, plyIndex + 1)
            })
        }
        return rows
    }
}
