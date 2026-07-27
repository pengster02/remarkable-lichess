import QtQuick 2.5

QtObject {
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
        if (status === "timeout") return "Opponent left"
        if (status === "draw") return "Draw"
        if (status === "outoftime") return "Time forfeit"
        if (status === "cheat") return "Cheat detected"
        if (status === "noStart") return "Opponent didn't join"
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
        if (speed === "chess960") return "Chess960"
        if (speed === "crazyhouse") return "Crazyhouse"
        if (speed === "antichess") return "Antichess"
        if (speed === "atomic") return "Atomic"
        if (speed === "horde") return "Horde"
        if (speed === "kingOfTheHill") return "King of the Hill"
        if (speed === "racingKings") return "Racing Kings"
        if (speed === "threeCheck") return "Three-check"
        return humanizeIdentifier(speed)
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

    function moveRows(moves, clocks, analysis) {
        var rows = []
        if (!moves) return rows
        for (var plyIndex = 0; plyIndex < moves.length; plyIndex += 2) {
            rows.push({
                number: Math.floor(plyIndex / 2) + 1,
                white: moveEntry(moves, clocks, analysis, plyIndex),
                black: moveEntry(moves, clocks, analysis, plyIndex + 1)
            })
        }
        return rows
    }
}
