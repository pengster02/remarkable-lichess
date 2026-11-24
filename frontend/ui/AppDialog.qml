import QtQuick 2.9

Item {
    id: dialog
    property bool darkMode: false
    property string title: ""
    property bool dismissOnBackground: true
    property int maximumWidth: 840
    property bool denseActions: true
    property bool pageByRow: false
    property Component footer: null
    default property alias content: dialogContent.data
    signal dismissed()

    function showPageContaining(item) {
        if (!item) return
        dialogContent.forceLayout()
        dialogFlickable.updatePageStops()
        dialogFlickable.showPageContaining(item.y, item.height)
    }

    Theme { id: theme; darkMode: dialog.darkMode }
    z: 100

    onVisibleChanged: {
        if (visible) dialogFlickable.contentY = 0
    }

    MouseArea {
        anchors.fill: parent
        onClicked: {
            if (dialog.dismissOnBackground) dialog.dismissed()
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - theme.pageSideMargin * 2, dialog.maximumWidth)
        height: Math.min(
            parent.height - theme.pageTopMargin - theme.pageBottomMargin,
            dialogContent.height + theme.spacingSmall * 2 +
                (footerLoader.active ? footerLoader.height + theme.spacingXs : 0)
        )
        color: theme.background
        border.width: 3
        border.color: theme.text
        radius: theme.dialogRadius

        Rectangle {
            anchors.left: parent.left
            anchors.leftMargin: theme.dialogRadius
            anchors.right: parent.right
            anchors.rightMargin: theme.dialogRadius
            anchors.top: parent.top
            anchors.topMargin: theme.spacingXs / 2
            height: theme.sectionRailWidth
            radius: height / 2
            color: theme.accentBackground
        }

        MouseArea {
            anchors.fill: parent
        }

        EinkPagedFlickable {
            id: dialogFlickable
            objectName: "dialogPager"
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: footerLoader.active ? footerLoader.top : parent.bottom
            anchors.margins: theme.spacingSmall
            anchors.bottomMargin: footerLoader.active ? theme.spacingXs : theme.spacingSmall
            contentHeight: dialogContent.height
            onPageHeightChanged: updatePageStops()

            function updatePageStops() {
                if (dialog.pageByRow && dialogContent) pageStops = rowPageStops(dialogContent.children)
            }

            Column {
                id: dialogContent
                width: dialogFlickable.width
                spacing: theme.spacingXs
                onPositioningComplete: dialogFlickable.updatePageStops()

                Text {
                    width: parent.width
                    text: dialog.title
                    visible: text.length > 0
                    font.pixelSize: theme.fontLarge
                    font.bold: true
                    horizontalAlignment: Text.AlignLeft
                    color: theme.text
                }
            }
        }

        Loader {
            id: footerLoader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: theme.spacingSmall
            active: dialog.footer !== null
            sourceComponent: dialog.footer
        }
    }
}
