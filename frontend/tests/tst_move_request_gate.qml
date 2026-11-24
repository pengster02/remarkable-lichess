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
        verify(gate.submit("e2", "e4", null, 1))
        compare(submitSpy.count, 1)
        compare(submitSpy.signalArguments[0][0].expected_game_id, "g1")
        compare(submitSpy.signalArguments[0][0].request_id, 1)
        compare(gate.pending.from, "e2")
        verify(!gate.submit("d2", "d4", null, 2))
        compare(submitSpy.count, 1)
    }

    function test_onlyMatchingBoardResolutionReleasesGate() {
        gate.submit("e2", "e4", null, 2)
        verify(!gate.matches("g2", 2))
        verify(!gate.resolve("g1", 1))
        verify(!gate.resolve("g1", undefined))
        verify(gate.pending !== null)
        verify(gate.resolve("g1", 2))
        compare(gate.pending, null)
    }

    function test_gameChangeClearsStaleMove() {
        gate.submit("e2", "e4", null, 3)
        verify(gate.resolve("g2", null))
        compare(gate.pending, null)
    }
}
