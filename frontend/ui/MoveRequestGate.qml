import QtQuick 2.5

QtObject {
    id: gate
    property string gameId: ""
    property var pending: null
    signal submitRequested(var message)

    function submit(from, to, promotion, requestId) {
        if (gate.gameId.length === 0 || gate.pending !== null) return false
        gate.pending = {
            gameId: gate.gameId,
            id: requestId,
            from: from,
            to: to,
            promotion: promotion
        }
        gate.submitRequested({
            type: "MakeMove",
            expected_game_id: gate.pending.gameId,
            request_id: requestId,
            from: from,
            to: to,
            promotion: promotion
        })
        return true
    }

    function matches(gameId, requestId) {
        return gate.pending !== null &&
            gate.pending.gameId === gameId &&
            gate.pending.id === requestId
    }

    function resolve(boardGameId, requestId) {
        if (gate.pending === null) return false
        if (gate.pending.gameId !== boardGameId || gate.matches(boardGameId, requestId)) {
            gate.clear()
            return true
        }
        return false
    }

    function clear() {
        gate.pending = null
    }
}
