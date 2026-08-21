import QtQuick 2.5

Item {
    id: pageHeader
    property bool darkMode: false
    property string eyebrow: ""
    property string title: ""
    property string detail: ""
    property string pieceSource: ""
    width: parent ? parent.width : implicitWidth
    height: headerColumn.height

    Theme { id: theme; darkMode: pageHeader.darkMode }

    Column {
        id: headerColumn
        width: parent.width
        spacing: theme.spacingSmall

        // A short annotation rule echoes a marked score sheet; a checker strip
        // was too busy, while a full-width color bar read as an alert.
        Row {
            width: parent.width
            height: Math.max(copyColumn.height, piecePlate.height)
            spacing: theme.spacingSmall

            Rectangle {
                id: piecePlate
                visible: pageHeader.pieceSource.length > 0
                width: visible ? 118 : 0
                height: visible ? 118 : 0
                color: theme.sectionRail

                Image {
                    anchors.centerIn: parent
                    source: pageHeader.pieceSource
                    width: parent.width * 0.82
                    height: width
                    fillMode: Image.PreserveAspectFit
                    smooth: false
                    sourceSize.width: width
                    sourceSize.height: height
                }
            }

            Column {
                id: copyColumn
                width: parent.width - piecePlate.width -
                    (piecePlate.visible ? parent.spacing : 0)
                anchors.verticalCenter: parent.verticalCenter
                spacing: theme.spacingXs / 2

                Text {
                    visible: pageHeader.eyebrow.length > 0
                    width: parent.width
                    text: pageHeader.eyebrow
                    font.pixelSize: theme.fontEyebrow
                    font.bold: true
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 2
                    color: theme.textMuted
                }

                Text {
                    width: parent.width
                    text: pageHeader.title
                    font.pixelSize: theme.fontHeading
                    font.bold: true
                    wrapMode: Text.WordWrap
                    color: theme.text
                }

                Text {
                    visible: pageHeader.detail.length > 0
                    width: parent.width
                    text: pageHeader.detail
                    font.pixelSize: theme.fontLabel
                    elide: Text.ElideRight
                    color: theme.textMuted
                }
            }
        }

        Row {
            width: parent.width
            height: 6

            Rectangle {
                width: parent.width * 0.18
                height: parent.height
                color: theme.accentBackground
            }

            Rectangle {
                width: parent.width * 0.82
                height: 2
                anchors.verticalCenter: parent.verticalCenter
                color: theme.divider
            }
        }
    }
}
