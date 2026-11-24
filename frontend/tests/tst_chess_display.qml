import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "ChessDisplay"
    when: windowShown
    width: 600
    height: 600

    ChessDisplay { id: display }

    function test_officialStatusesAreReadable() {
        compare(display.terminationLabel("outoftime"), "Time forfeit")
        compare(display.terminationLabel("noStart"), "First move deadline missed")
        compare(display.terminationLabel("timeout"), "Disconnection")
        compare(display.terminationLabel("unknownFinish"), "Unknown finish")
        compare(display.terminationLabel("insufficientMaterialClaim"), "Insufficient material")
    }

    function test_speedAndVariantIdentifiersAreReadable() {
        compare(display.speedLabel("ultraBullet"), "UltraBullet")
        compare(display.speedLabel("kingOfTheHill"), "King of the Hill")
        compare(display.speedLabel("threeCheck"), "Three-check")
        compare(display.speedLabel("futureSpeedMode"), "Future Speed Mode")
    }

    function test_moveRowsPairWhiteAndBlackPlies() {
        var rows = display.moveRows(
            ["e4", "e5", "Nf3"],
            [599000, 598000, 3900000],
            [{judgment: null}, {judgment: "Mistake"}, {judgment: "Blunder"}]
        )
        compare(rows.length, 2)
        compare(rows[0].number, 1)
        compare(rows[0].white.san, "e4")
        compare(rows[0].black.san, "e5?")
        compare(rows[0].black.clockLabel, "9:58")
        compare(rows[1].white.san, "Nf3??")
        compare(rows[1].white.clockLabel, "1:05:00")
        compare(rows[1].black, null)
    }

    function test_moveRowsKeepBlackFirstCustomNumberingAndSelection() {
        var initialFen = "4k3/4p3/8/8/8/8/P7/4K3 b - - 0 17"
        var rows = display.moveRows(["e5", "a4"], [599000, 598000], [], initialFen)
        compare(rows.length, 2)
        compare(rows[0].number, 17)
        compare(rows[0].white, null)
        compare(rows[0].black.san, "e5")
        compare(rows[0].black.clockLabel, "9:59")
        compare(rows[0].black.fenIndex, 1)
        compare(rows[1].number, 18)
        compare(rows[1].white.san, "a4")
        compare(rows[1].white.fenIndex, 2)
        compare(display.moveRowIndex(1, initialFen), 0)
        compare(display.moveRowIndex(2, initialFen), 1)
        compare(display.moveRows([], [], [], initialFen).length, 0)
    }

    function test_resultFallbackNeverLeaksCamelCase() {
        compare(display.resultLabel("win"), "Win")
        compare(display.resultLabel("noStart"), "First move deadline missed")
        compare(display.resultLabel("futureFinishReason"), "Future Finish Reason")
    }
}
