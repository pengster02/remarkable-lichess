import QtQuick 2.5

// Long pages on e-ink must not kinetic-scroll: every dragged frame damages a
// large region and forces repeated refreshes. This control keeps the Flickable
// non-interactive and only changes contentY once per Prev/Next page action,
// asking for a slow Content waveform over the viewport.
Item {
    id: pager
    default property alias contentData: contentHost.data
    property alias contentHeight: viewport.contentHeight
    property alias contentY: viewport.contentY
    property bool darkMode: nearestDarkMode(parent)
    readonly property bool pagingNeeded: contentHeight > pageViewport.height + 1
    readonly property bool continuousScrollingEnabled: viewport.interactive
    readonly property real pageHeight: viewport.height
    readonly property real pageStep: Math.max(1, viewport.height - theme.spacingSmall)
    readonly property real maximumContentY: Math.max(0, contentHeight - viewport.height)
    readonly property real visibleFraction: contentHeight > 0
        ? Math.min(1, pageViewport.height / contentHeight)
        : 1
    readonly property real scrollProgress: maximumContentY > 0
        ? contentY / maximumContentY
        : 0
    readonly property int currentPage: pageStep > 0
        ? Math.floor(contentY / pageStep) + 1
        : 1
    readonly property int pageCount: pageStep > 0
        ? Math.max(1, Math.ceil(Math.max(contentHeight - viewport.height, 0) / pageStep) + 1)
        : 1

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

    function pageUp() {
        moveTo(viewport.contentY - pager.pageStep)
    }

    function pageDown() {
        moveTo(viewport.contentY + pager.pageStep)
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
            interactive: false
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Item {
                id: contentHost
                width: viewport.width
                height: viewport.contentHeight
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
            enabled: pager.contentY > 0
            text: "Prev"
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
            enabled: pager.contentY < pager.maximumContentY
            text: "Next"
            onClicked: pager.pageDown()
        }
    }
}
