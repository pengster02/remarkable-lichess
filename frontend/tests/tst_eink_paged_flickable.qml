import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "EinkPagedFlickable"
    when: windowShown
    visible: true
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
        contentHeight: 800
        pageStops: [550, 275, 275, -5, 900, Infinity, 0]
    }

    EinkPagedFlickable {
        id: tallSectionPager
        width: 600
        height: 310
        contentHeight: 1140
        pageStops: [0, 400, 800]
    }

    EinkPagedFlickable {
        id: shortLogicalPager
        width: 600
        height: 400
        visible: false
        contentHeight: 350
        pageStops: [0, 100]
    }

    function init() {
        pager.contentHeight = 1200
        pager.moveTo(0)
        logicalPager.moveTo(0)
        tallSectionPager.moveTo(0)
    }

    function test_logicalPagesLandOnSectionStarts() {
        logicalPager.pageDown()
        compare(logicalPager.contentY, 275)
        compare(logicalPager.currentPage, 2)
        logicalPager.pageDown()
        compare(logicalPager.contentY, 550)
        compare(logicalPager.currentPage, 3)
        compare(logicalPager.pageCount, 3)
        logicalPager.pageDown()
        compare(logicalPager.contentY, 550)
        logicalPager.pageUp()
        compare(logicalPager.contentY, 275)
    }

    function test_longSectionsFillGapsAndReachTheEnd() {
        var visited = [0]
        var count = tallSectionPager.pageCount
        verify(count > 3)
        for (var i = 1; i < count; i++) {
            var previous = tallSectionPager.contentY
            tallSectionPager.pageDown()
            verify(tallSectionPager.contentY > previous)
            verify(tallSectionPager.contentY - previous <= tallSectionPager.pageHeight)
            compare(tallSectionPager.currentPage, i + 1)
            visited.push(tallSectionPager.contentY)
        }
        verify(visited.indexOf(400) !== -1)
        verify(visited.indexOf(800) !== -1)
        compare(tallSectionPager.contentY, tallSectionPager.maximumContentY)
        for (var j = visited.length - 2; j >= 0; j--) {
            tallSectionPager.pageUp()
            compare(tallSectionPager.contentY, visited[j])
        }
    }

    function test_continuousScrollingIsDisabled() {
        compare(pager.continuousScrollingEnabled, false)
        compare(pager.pagingNeeded, true)
        verify(pager.pageCount > 1)
        verify(pager.pageStep > 0)
        verify(pager.pageStep < pager.height)
    }

    function test_shortLogicalContentDoesNotCreatePhantomPages() {
        compare(shortLogicalPager.pagingNeeded, false)
        compare(shortLogicalPager.maximumContentY, 0)
        compare(shortLogicalPager.pageCount, 1)
    }

    function test_pageControlsJumpAndClamp_data() {
        return [{tag: "exact last page", extra: 0}, {tag: "partial last page", extra: 44}]
    }

    function test_pageControlsJumpAndClamp(data) {
        pager.contentHeight = pager.pageHeight + (pager.pageStep * 3) + data.extra
        var pageNumber = findChild(pager, "pageNumber")
        var next = findChild(pager, "pageDownButton")
        var previous = findChild(pager, "pageUpButton")
        var count = data.extra ? 5 : 4
        compare(pager.pageCount, count)
        for (var i = 1; i < count; i++) {
            verify(next.enabled)
            pager.pageDown()
            compare(pager.contentY, Math.min(pager.pageStep * i, pager.maximumContentY))
            compare(pageNumber.text, (i + 1) + " / " + count)
        }
        compare(pager.contentY, pager.maximumContentY)
        verify(!next.enabled)
        for (var j = count - 2; j >= 0; j--) {
            verify(previous.enabled)
            pager.pageUp()
            compare(pager.contentY, pager.pageStep * j)
        }
        verify(!previous.enabled)
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
        pager.pageUp()
        compare(pager.contentY, 0)
    }

    function test_shorterContentClampsAnOldOffset() {
        pager.moveTo(pager.maximumContentY)
        verify(pager.currentPage > 1)
        pager.contentHeight = 180
        tryCompare(pager, "contentY", 0)
        compare(pager.pageCount, 1)
        verify(!pager.pagingNeeded)
        pager.contentHeight = 920
        compare(pager.currentPage, 1)
        verify(pager.pageCount > 1)
    }
}
