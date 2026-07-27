import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "EinkPagedFlickable"
    when: windowShown
    width: 600
    height: 400

    EinkPagedFlickable {
        id: pager
        anchors.fill: parent
        contentHeight: 1200
    }

    function init() {
        pager.moveTo(0)
    }

    function test_continuousScrollingIsDisabled() {
        compare(pager.continuousScrollingEnabled, false)
        compare(pager.pagingNeeded, true)
        fuzzyCompare(pager.visibleFraction, 1 / 3, 0.001)
    }

    function test_scrollIndicatorTracksPosition() {
        pager.moveTo(400)
        fuzzyCompare(pager.scrollProgress, 0.5, 0.001)
    }

    function test_pageControlsJumpAndClamp() {
        pager.pageDown()
        compare(pager.contentY, 374)
        pager.pageDown()
        compare(pager.contentY, 748)
        pager.pageDown()
        compare(pager.contentY, 800)
        pager.pageUp()
        compare(pager.contentY, 426)
    }
}
