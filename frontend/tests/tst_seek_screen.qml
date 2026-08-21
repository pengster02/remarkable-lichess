import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "SeekScreen"
    when: windowShown
    width: 960
    height: 1696

    SeekScreen {
        id: seek
        width: 960
        height: 1696
        backendSender: function() {}
        navigateTo: function() {}
    }

    function test_secondPageBeginsAtPlayerChallenge() {
        var pager = findChild(seek, "seekFlickable")
        var challenge = findChild(seek, "playerChallengeSection")
        verify(pager !== null)
        verify(challenge !== null)
        pager.moveTo(0)
        pager.pageDown()
        fuzzyCompare(pager.contentY, challenge.y, 1)
        fuzzyCompare(challenge.mapToItem(pager, 0, 0).y, 0, 1)
        compare(pager.currentPage, 2)
        compare(pager.pageCount, 2)
    }
}
