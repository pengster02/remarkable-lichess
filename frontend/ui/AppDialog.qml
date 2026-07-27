import QtQuick 2.5

Item {
    id: dialog
    property bool darkMode: false
    property string title: ""
    property bool dismissOnBackground: true
    property int maximumWidth: 840
    default property alias content: dialogContent.data
    signal dismissed()

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
            dialogContent.height + theme.spacingSmall * 2
        )
        color: theme.background
        border.width: 3
        border.color: theme.text
        radius: theme.cardRadius

        MouseArea {
            anchors.fill: parent
        }

        Flickable {
            id: dialogFlickable
            anchors.fill: parent
            anchors.margins: theme.spacingSmall
            contentWidth: width
            contentHeight: dialogContent.height
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Column {
                id: dialogContent
                width: dialogFlickable.width
                spacing: theme.spacingXs

                Text {
                    width: parent.width
                    text: dialog.title
                    visible: text.length > 0
                    font.pixelSize: theme.fontLarge
                    font.bold: true
                    horizontalAlignment: Text.AlignHCenter
                    color: theme.text
                }
            }
        }
    }
}
