import QtQuick 2.5

Item {
    id: pager
    default property alias contentData: contentHost.data
    property alias contentHeight: viewport.contentHeight
    property alias contentY: viewport.contentY
    property bool darkMode: nearestDarkMode(parent)
    readonly property bool pagingNeeded: contentHeight > viewport.height + 1
    readonly property bool continuousScrollingEnabled: viewport.interactive
    readonly property real pageHeight: viewport.height
    readonly property real maximumContentY: Math.max(0, contentHeight - viewport.height)
    readonly property real visibleFraction: contentHeight > 0
        ? Math.min(1, viewport.height / contentHeight)
        : 1
    readonly property real scrollProgress: maximumContentY > 0
        ? contentY / maximumContentY
        : 0

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
        moveTo(viewport.contentY - Math.max(1, viewport.height - theme.spacingSmall))
    }

    function pageDown() {
        moveTo(viewport.contentY + Math.max(1, viewport.height - theme.spacingSmall))
    }

    function reveal(y, itemHeight) {
        if (y < viewport.contentY)
            moveTo(y)
        else if (y + itemHeight > viewport.contentY + viewport.height)
            moveTo(y + itemHeight - viewport.height)
    }

    Theme { id: theme; darkMode: pager.darkMode }

    Flickable {
        id: viewport
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: pageRail.visible ? theme.spacingSmall : 0
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

    Item {
        id: pageRail
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: theme.spacingSmall
        visible: pager.pagingNeeded

        Rectangle {
            id: scrollTrack
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: theme.spacingSmall
            anchors.bottomMargin: theme.spacingSmall
            width: 6
            radius: width / 2
            color: theme.cardBorder
        }

        Rectangle {
            width: 10
            height: Math.max(36, scrollTrack.height * pager.visibleFraction)
            radius: width / 2
            x: scrollTrack.x + (scrollTrack.width - width) / 2
            y: scrollTrack.y +
                (scrollTrack.height - height) * pager.scrollProgress
            color: theme.text
        }

        MouseArea {
            objectName: "pageUpButton"
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: parent.height / 2
            enabled: pager.contentY > 0
            onClicked: pager.pageUp()
        }

        MouseArea {
            objectName: "pageDownButton"
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: parent.height / 2
            enabled: pager.contentY < pager.maximumContentY
            onClicked: pager.pageDown()
        }
    }
}
