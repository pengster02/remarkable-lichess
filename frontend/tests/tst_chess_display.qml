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
        compare(display.terminationLabel("noStart"), "Opponent didn't join")
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

    function test_resultFallbackNeverLeaksCamelCase() {
        compare(display.resultLabel("win"), "Win")
        compare(display.resultLabel("noStart"), "Opponent didn't join")
        compare(display.resultLabel("futureFinishReason"), "Future Finish Reason")
    }
}
