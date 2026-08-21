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

    EinkPagedFlickable {
        id: logicalPager
        width: 600
        height: 400
        visible: false
        contentHeight: 1200
        pageStops: [0, 275, 725]
    }

    function init() {
        pager.moveTo(0)
        logicalPager.moveTo(0)
    }

    function test_logicalPagesLandOnSectionStarts() {
        logicalPager.pageDown()
        compare(logicalPager.contentY, 275)
        compare(logicalPager.currentPage, 2)
        logicalPager.pageDown()
        compare(logicalPager.contentY, 725)
        compare(logicalPager.currentPage, 3)
        compare(logicalPager.pageCount, 3)
        logicalPager.pageDown()
        compare(logicalPager.contentY, 725)
        logicalPager.pageUp()
        compare(logicalPager.contentY, 275)
    }

    function test_continuousScrollingIsDisabled() {
        compare(pager.continuousScrollingEnabled, false)
        compare(pager.pagingNeeded, true)
        verify(pager.pageCount > 1)
        verify(pager.pageStep > 0)
        verify(pager.pageStep < pager.height)
    }

    function test_pageControlsJumpAndClamp() {
        var step = pager.pageStep
        verify(step > 0)
        pager.pageDown()
        compare(pager.contentY, step)
        pager.pageDown()
        compare(pager.contentY, step * 2)
        pager.pageDown()
        compare(pager.contentY, Math.min(step * 3, pager.maximumContentY))
        while (pager.contentY < pager.maximumContentY)
            pager.pageDown()
        compare(pager.contentY, pager.maximumContentY)
        pager.pageUp()
        compare(pager.contentY, Math.max(0, pager.maximumContentY - step))
    }

    function test_scrollIndicatorTracksPosition() {
        pager.moveTo(pager.maximumContentY / 2)
        fuzzyCompare(pager.scrollProgress, 0.5, 0.001)
    }

    function test_revealSkipsWhenAlreadyVisible() {
        pager.moveTo(0)
        compare(pager.reveal(10, 40), false)
        compare(pager.contentY, 0)
        compare(pager.reveal(pager.pageHeight + 50, 40), true)
        verify(pager.contentY > 0)
    }
}
