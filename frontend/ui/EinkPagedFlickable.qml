import QtQuick 2.5

// Long pages on e-ink must not kinetic-scroll: every dragged frame damages a
// large region and forces repeated refreshes. This control keeps the Flickable
// non-interactive and only changes contentY once per Prev/Next page action,
// asking for a slow Content waveform over the viewport.
Item {
    id: pager
    default property alias contentData: contentHost.data
    property alias contentHeight: contentHost.height
    property alias contentY: viewport.contentY
    property bool darkMode: nearestDarkMode(parent)
    property var pageStops: []
    signal pageNavigationRequested()
    // Raw content height breaks the page-bar visibility loop. Always reserving
    // the bar and deferring the check were the alternatives, but each wastes
    // space or creates a second layout pass.
    readonly property bool pagingNeeded: contentHost.height > pager.height + 1
    readonly property bool continuousScrollingEnabled: viewport.interactive
    readonly property real pageHeight: viewport.height
    readonly property real pageStep: Math.max(1, viewport.height - theme.spacingSmall)
    readonly property real maximumContentY: Math.max(
        0,
        viewport.contentHeight - viewport.height
    )
    readonly property real visibleFraction: viewport.contentHeight > 0
        ? Math.min(1, pageViewport.height / viewport.contentHeight)
        : 1
    readonly property real scrollProgress: maximumContentY > 0
        ? contentY / maximumContentY
        : 0
    // Explicit section stops beat per-screen pagers or fragile child discovery:
    // screens keep layout intent while this control retains one paging policy.
    readonly property var effectivePageStops: normalizedPageStops()
    readonly property bool usesPageStops: pageStops && pageStops.length > 0
    readonly property real requestedLastStop: largestRequestedPageStop()
    readonly property int currentPage: usesPageStops
        ? pageIndexFor(contentY) + 1
        : (pageStep > 0 ? Math.floor(contentY / pageStep) + 1 : 1)
    readonly property int pageCount: usesPageStops
        ? effectivePageStops.length
        : (pageStep > 0
            ? Math.max(1, Math.ceil(Math.max(contentHeight - viewport.height, 0) / pageStep) + 1)
            : 1)

    function nearestDarkMode(item) {
        while (item) {
            if (item.hasOwnProperty("darkMode")) return item.darkMode
            item = item.parent
        }
        return false
    }

    function moveTo(y) {
        viewport.contentY = Math.max(0, Math.min(pager.maximumContentY, y))
    }

    function largestRequestedPageStop() {
        var largest = 0
        if (!pageStops) return largest
        for (var i = 0; i < pageStops.length; ++i) {
            var candidate = Number(pageStops[i])
            if (!isNaN(candidate)) largest = Math.max(largest, candidate)
        }
        return largest
    }

    function normalizedPageStops() {
        var stops = [0]
        if (pageStops) {
            for (var i = 0; i < pageStops.length; ++i) {
                var candidate = Number(pageStops[i])
                if (!isNaN(candidate))
                    stops.push(Math.max(0, Math.min(maximumContentY, candidate)))
            }
        }
        stops.sort(function(a, b) { return a - b })

        var unique = []
        for (var j = 0; j < stops.length; ++j) {
            if (unique.length === 0 || Math.abs(stops[j] - unique[unique.length - 1]) > 1)
                unique.push(stops[j])
        }
        return unique
    }

    function pageIndexFor(y) {
        var stops = effectivePageStops
        var index = 0
        for (var i = 1; i < stops.length; ++i) {
            if (stops[i] <= y + 1) index = i
            else break
        }
        return index
    }

    function pageUp() {
        pager.pageNavigationRequested()
        if (!usesPageStops) {
            moveTo(viewport.contentY - pager.pageStep)
            return
        }
        var index = pageIndexFor(viewport.contentY)
        if (effectivePageStops[index] >= viewport.contentY - 1) index--
        moveTo(effectivePageStops[Math.max(0, index)])
    }

    function pageDown() {
        pager.pageNavigationRequested()
        if (!usesPageStops) {
            moveTo(viewport.contentY + pager.pageStep)
            return
        }
        var index = pageIndexFor(viewport.contentY)
        moveTo(effectivePageStops[Math.min(effectivePageStops.length - 1, index + 1)])
    }

    function reveal(y, itemHeight) {
        // No-op when the row is already fully on screen -- avoids a contentY
        // write (and a full Content refresh) on every Prev/Next in review.
        if (y >= viewport.contentY &&
                y + itemHeight <= viewport.contentY + viewport.height) {
            return false
        }
        if (y < viewport.contentY)
            moveTo(y)
        else
            moveTo(y + itemHeight - viewport.height)
        return true
    }

    Theme { id: theme; darkMode: pager.darkMode }

    Item {
        id: pageViewport
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: pageBar.visible ? pageBar.top : parent.bottom
        anchors.bottomMargin: pageBar.visible ? theme.spacingXs : 0

        // Behind the Flickable so it never steals taps; still covers the
        // damaged region AppLoad uses for waveform selection.
        EinkRefreshArea {
            anchors.fill: parent
            displayMethod: EinkRefreshArea.Content
        }

        Flickable {
            id: viewport
            anchors.fill: parent
            z: 1
            contentWidth: width
            contentHeight: Math.max(
                contentHost.height,
                pager.usesPageStops && pager.pagingNeeded
                    ? pager.requestedLastStop + height
                    : contentHost.height
            )
            interactive: false
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Item {
                id: contentHost
                width: viewport.width
            }
        }
    }

    Row {
        id: pageBar
        objectName: "pageBar"
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: theme.touchTarget
        spacing: theme.spacingSmall
        visible: pager.pagingNeeded

        AppButton {
            objectName: "pageUpButton"
            darkMode: pager.darkMode
            compact: true
            width: Math.max(theme.touchTarget * 2, (pageBar.width - theme.spacingSmall * 2) / 3)
            height: parent.height
            enabled: pager.usesPageStops
                ? pager.currentPage > 1
                : pager.contentY > 0
            text: "Previous"
            onClicked: pager.pageUp()
        }

        Text {
            width: Math.max(theme.touchTarget, (pageBar.width - theme.spacingSmall * 2) / 3)
            height: parent.height
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: theme.fontLabel
            color: theme.textMuted
            text: pager.currentPage + " / " + pager.pageCount
        }

        AppButton {
            objectName: "pageDownButton"
            darkMode: pager.darkMode
            compact: true
            width: Math.max(theme.touchTarget * 2, (pageBar.width - theme.spacingSmall * 2) / 3)
            height: parent.height
            enabled: pager.usesPageStops
                ? pager.currentPage < pager.pageCount
                : pager.contentY < pager.maximumContentY
            text: "Next"
            onClicked: pager.pageDown()
        }
    }
}
