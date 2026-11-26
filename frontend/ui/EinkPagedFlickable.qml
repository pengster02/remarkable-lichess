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
    property bool keepRowsTogether: false
    signal pageNavigationRequested()
    // Raw content height breaks the page-bar visibility loop. Always reserving
    // the bar and deferring the check were the alternatives, but each wastes
    // space or creates a second layout pass.
    readonly property bool pagingNeeded: contentHost.height > pager.height + 1
    readonly property bool continuousScrollingEnabled: viewport.interactive
    readonly property real pageHeight: keepRowsTogether ? pageViewport.height : viewport.height
    readonly property real visiblePageHeight: viewport.height
    readonly property real pageControlsHeight: pageBar.height + theme.spacingXs
    readonly property real pageStep: Math.max(1, (keepRowsTogether ? pageHeight : viewport.height) - theme.spacingSmall)
    readonly property real maximumContentY: Math.max(
        0,
        viewport.contentHeight - (keepRowsTogether ? pageHeight : viewport.height)
    )
    readonly property real visibleFraction: viewport.contentHeight > 0
        ? Math.min(1, pageViewport.height / viewport.contentHeight)
        : 1
    readonly property real scrollProgress: maximumContentY > 0
        ? contentY / maximumContentY
        : 0
    readonly property real positionTolerance: 0.01
    readonly property var requestedPageStops: normalizedPageStops()
    readonly property real requestedLastStop: requestedPageStops[requestedPageStops.length - 1]
    // One list drives both direction and numbering. Stride arithmetic misses
    // a partial last page, and section anchors alone can skip long content.
    readonly property var effectivePageStops: pageOrigins()
    readonly property int currentPage: (keepRowsTogether ? pageViewport.rowPageIndex : pageIndexFor(contentY)) + 1
    readonly property int pageCount: effectivePageStops.length

    onMaximumContentYChanged: {
        if (!keepRowsTogether && contentY > maximumContentY) moveTo(maximumContentY)
    }
    onEffectivePageStopsChanged: {
        if (keepRowsTogether && viewport) {
            moveTo(effectivePageStops[Math.min(pageViewport.rowPageIndex, pageCount - 1)])
        }
    }

    function nearestDarkMode(item) {
        while (item) {
            if (item.hasOwnProperty("darkMode")) return item.darkMode
            item = item.parent
        }
        return false
    }

    function moveTo(y) {
        if (keepRowsTogether) {
            pageViewport.rowPageIndex = pageIndexFor(y)
            y = effectivePageStops[pageViewport.rowPageIndex]
        }
        viewport.contentY = Math.max(0, Math.min(pager.maximumContentY, y))
    }

    function rowPageStops(items) {
        var lastOrigin = Math.max(0, pager.contentHeight - pager.pageHeight)
        var stops = []
        var origin = 0
        if (pager.pageHeight < 1) return stops
        // Fixed strides can split a row on both pages, and fixed row counts miss wrapped rows.
        for (var index = 0; index < items.length && origin < lastOrigin; index++) {
            var row = items[index]
            if (!row.visible || row.height <= 0 || row.y + row.height <= origin + pager.pageHeight) continue
            // A bottom-aligned last page can start inside a row. Keeping its start
            // may leave blank space, while overlapping pages can repeat actions.
            var nextOrigin = keepRowsTogether ? row.y : Math.min(row.y, lastOrigin)
            if (nextOrigin > origin) {
                origin = nextOrigin
                stops.push(origin)
            }
            // Only an oversized row needs an internal page break. Split at full
            // heights to retain its details without overlapping or truncating them.
            while (keepRowsTogether && row.y + row.height > origin + pager.pageHeight + positionTolerance) {
                origin += pager.pageHeight
                stops.push(origin)
            }
        }
        return stops
    }

    function normalizedPageStops() {
        var stops = [0]
        var requested = pager.pageStops || []
        for (var i = 0; i < requested.length; ++i) {
            var candidate = Number(requested[i])
            if (candidate > 0 && candidate < contentHost.height) stops.push(candidate)
        }
        stops.sort(function(a, b) { return a - b })

        var unique = [0]
        for (var j = 1; j < stops.length; ++j) {
            if (stops[j] - unique[unique.length - 1] > pager.positionTolerance)
                unique.push(stops[j])
        }
        return unique
    }

    function pageOrigins() {
        var origins = [0]
        if (!pager.pagingNeeded || pager.pageHeight < 1) return origins

        var targets = pager.requestedPageStops.slice(1)
        var last = pager.maximumContentY
        if (last > pager.requestedLastStop) targets.push(last)
        // Preserve section starts when the gap fits. Fixed steps everywhere
        // would move those starts, while jumping straight there can miss rows.
        // Measured rows already supply internal breaks. A larger gap between
        // their starts can be spacing, where adding a page leaves it empty.
        var maxGap = keepRowsTogether ? Infinity
            : pager.requestedPageStops.length > 1 ? pager.pageHeight : pager.pageStep
        var origin = 0
        for (var i = 0; i < targets.length; ++i) {
            var target = targets[i]
            while (target - origin > maxGap + pager.positionTolerance) {
                origin += pager.pageStep
                origins.push(origin)
            }
            if (target - origin > pager.positionTolerance) {
                origins.push(target)
            } else if (origin > 0) {
                origins[origins.length - 1] = target
            }
            origin = target
        }
        return origins
    }

    function pageIndexFor(y) {
        var stops = effectivePageStops
        var index = 0
        for (var i = 1; i < stops.length; ++i) {
            if (stops[i] <= y + pager.positionTolerance) index = i
            else break
        }
        return index
    }

    function pageUp() {
        pager.pageNavigationRequested()
        var index = pageIndexFor(viewport.contentY)
        if (effectivePageStops[index] >= viewport.contentY - pager.positionTolerance) index--
        moveTo(effectivePageStops[Math.max(0, index)])
    }

    function pageDown() {
        pager.pageNavigationRequested()
        var index = pageIndexFor(viewport.contentY)
        moveTo(effectivePageStops[Math.min(effectivePageStops.length - 1, index + 1)])
    }

    function showPageContaining(y, itemHeight) {
        // Page origins keep Prev and Next aligned. Scrolling to the row can split adjacent rows, while a fixed row count misses layout changes.
        var stops = effectivePageStops
        var index = pageIndexFor(y)
        while (index > 0 && y + itemHeight <= stops[index - 1] + pageHeight + positionTolerance) {
            index--
        }
        moveTo(stops[index])
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
        property int rowPageIndex: 0
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
            objectName: "pagedViewport"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: pager.keepRowsTogether ? undefined : parent.bottom

            // Clip the next row at its start. Fixed-height clipping exposes an
            // incomplete action, and hiding delegates would change their layout.
            Binding {
                target: viewport
                property: "height"
                when: pager.keepRowsTogether
                value: pager.currentPage < pager.pageCount
                    ? Math.min(pager.pageHeight, pager.effectivePageStops[pager.currentPage] - pager.contentY)
                    : pager.pageHeight
            }
            z: 1
            contentWidth: width
            contentHeight: Math.max(
                contentHost.height,
                pager.pagingNeeded
                    ? pager.requestedLastStop + (pager.keepRowsTogether ? pager.pageHeight : height)
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
        readonly property real availableWidth: Math.max(0, width - spacing * 2)
        readonly property real buttonWidth: (availableWidth - pageNumber.width) / 2

        TextMetrics {
            id: pageNumberMetrics
            font: pageNumber.font
            text: pager.pageCount + " / " + pager.pageCount
        }

        AppButton {
            objectName: "pageUpButton"
            darkMode: pager.darkMode
            compact: true
            width: pageBar.buttonWidth
            height: parent.height
            enabled: pager.contentY > pager.positionTolerance
            text: "Previous"
            onClicked: pager.pageUp()
        }

        Text {
            id: pageNumber
            objectName: "pageNumber"
            // Share one width budget. Fixed minimums can overflow, and equal
            // thirds can clip the counter before the buttons need the space.
            width: Math.min(Math.max(0, pageBar.availableWidth - theme.touchTarget * 2),
                Math.max(Math.ceil(pageNumberMetrics.advanceWidth), Math.min(pageBar.availableWidth / 3,
                    pageBar.availableWidth - theme.touchTarget * 4)))
            height: parent.height
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            font.pixelSize: theme.fontLabel
            color: theme.textMuted
            elide: Text.ElideRight
            text: pager.currentPage + " / " + pager.pageCount
        }

        AppButton {
            objectName: "pageDownButton"
            darkMode: pager.darkMode
            compact: true
            width: pageBar.buttonWidth
            height: parent.height
            enabled: pager.currentPage < pager.pageCount
            text: "Next"
            onClicked: pager.pageDown()
        }
    }
}
