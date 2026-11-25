.pragma library

// Match the backend's single-packet snapshot budget. FEN and SAN are ASCII.
var maximumSavedBytes = 96 * 1024

function position(variations, ply, fen) {
    return variations.positions.find(function(entry) {
        return entry.ply === ply && entry.fen === fen
    }) || {ply: ply, fen: fen, nodes: []}
}

function addMove(variations, root, parent, san, fen) {
    var existing = root.nodes.findIndex(function(node) {
        return node.parent === parent && node.san === san && node.fen === fen
    })
    if (existing >= 0) return {variations: variations, nodeIndex: existing}

    var updated = {ply: root.ply, fen: root.fen,
                   nodes: root.nodes.concat([{parent: parent, san: san, fen: fen}])}
    var positions = variations.positions.slice()
    var index = positions.findIndex(function(entry) {
        return entry.ply === root.ply && entry.fen === root.fen
    })
    if (index < 0) positions.push(updated)
    else positions[index] = updated
    return {variations: {positions: positions}, nodeIndex: root.nodes.length}
}

function line(root, nodeIndex, baseFen) {
    var moves = []
    var fens = []
    while (nodeIndex !== null) {
        var node = root.nodes[nodeIndex]
        moves.push(node.san)
        fens.push(node.fen)
        nodeIndex = node.parent
    }
    fens.push(baseFen)
    return {moves: moves.reverse(), fens: fens.reverse()}
}

function tips(root) {
    var parents = new Set(root.nodes.map(function(node) { return node.parent }))
    var rows = []
    for (var index = 0; index < root.nodes.length; index++) {
        if (parents.has(index)) continue
        var moves = line(root, index, root.fen).moves
        rows.push({nodeIndex: index, label: moves.join(" ")})
    }
    return rows
}
