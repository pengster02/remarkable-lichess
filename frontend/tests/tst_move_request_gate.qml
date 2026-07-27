import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "MoveRequestGate"
    when: windowShown
    width: 600
    height: 500

    MoveRequestGate {
        id: gate
        gameId: "g1"
    }

    SignalSpy {
        id: submitSpy
        target: gate
        signalName: "submitRequested"
    }

    function init() {
        gate.clear()
        gate.gameId = "g1"
        submitSpy.clear()
    }

    function test_submitBlocksDuplicates() {
        verify(gate.submit("e2", "e4", null))
        compare(submitSpy.count, 1)
        compare(gate.pending.from, "e2")
        verify(!gate.submit("d2", "d4", null))
        compare(submitSpy.count, 1)
    }

    function test_acknowledgeMustMatch() {
        gate.submit("e7", "e8", "q")
        verify(!gate.acknowledge("g1", "e7", "e8", "r"))
        compare(gate.accepted, false)
        verify(gate.acknowledge("g1", "e7", "e8", "q"))
        compare(gate.accepted, true)
        verify(gate.pending !== null)
    }

    function test_matchingStreamMoveReleasesGate() {
        gate.submit("e2", "e4", null)
        verify(!gate.resolve("g1", ["d2", "d4"]))
        verify(gate.pending !== null)
        verify(gate.resolve("g1", ["e2", "e4"]))
        compare(gate.pending, null)
        compare(gate.accepted, false)
    }

    function test_gameChangeClearsStaleMove() {
        gate.submit("e2", "e4", null)
        verify(gate.resolve("g2", null))
        compare(gate.pending, null)
    }
}
