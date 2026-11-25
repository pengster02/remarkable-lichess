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

function moveKey(parent, node) {
    return JSON.stringify([parent, node.san, node.fen])
}

function mergeSavedNodes(localNodes, savedNodes) {
    var nodes = localNodes.slice()
    var indices = new Map()
    nodes.forEach(function(node, index) {
        indices.set(moveKey(node.parent, node), index)
    })
    var savedIndices = []
    savedNodes.forEach(function(node) {
        var parent = node.parent === null ? null : savedIndices[node.parent]
        var key = moveKey(parent, node)
        var index = indices.get(key)
        if (index === undefined) {
            index = nodes.length
            nodes.push({parent: parent, san: node.san, fen: node.fen})
            indices.set(key, index)
        }
        savedIndices.push(index)
    })
    return nodes
}

function mergeSaved(local, saved) {
    if (local.positions.length === 0) return saved

    // Replacing loses unsaved moves. Starting from saved indices can change the selected line.
    var positions = local.positions.slice()
    saved.positions.forEach(function(entry) {
        var index = positions.findIndex(function(position) {
            return position.ply === entry.ply && position.fen === entry.fen
        })
        if (index < 0) {
            positions.push(entry)
        } else {
            positions[index] = {ply: entry.ply, fen: entry.fen,
                                nodes: mergeSavedNodes(positions[index].nodes, entry.nodes)}
        }
    })
    return {positions: positions}
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
