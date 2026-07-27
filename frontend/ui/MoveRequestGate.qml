import QtQuick 2.5

QtObject {
    id: gate
    property string gameId: ""
    property var pending: null
    property bool accepted: false
    signal submitRequested(var message)

    function submit(from, to, promotion) {
        if (gate.pending !== null) return false
        gate.pending = {
            gameId: gate.gameId,
            from: from,
            to: to,
            promotion: promotion
        }
        gate.accepted = false
        gate.submitRequested({
            type: "MakeMove",
            from: from,
            to: to,
            promotion: promotion
        })
        return true
    }

    function matches(gameId, from, to, promotion) {
        return gate.pending !== null &&
            gate.pending.gameId === gameId &&
            gate.pending.from === from &&
            gate.pending.to === to &&
            (gate.pending.promotion || null) === (promotion || null)
    }

    function acknowledge(gameId, from, to, promotion) {
        if (!gate.matches(gameId, from, to, promotion)) return false
        gate.accepted = true
        return true
    }

    function resolve(boardGameId, lastMove) {
        if (gate.pending === null) return false
        if (gate.pending.gameId !== boardGameId) {
            gate.clear()
            return true
        }
        if (lastMove !== null &&
                gate.pending.from === lastMove[0] &&
                gate.pending.to === lastMove[1]) {
            gate.clear()
            return true
        }
        return false
    }

    function clear() {
        gate.pending = null
        gate.accepted = false
    }
}
