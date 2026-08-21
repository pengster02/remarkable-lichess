import QtQuick 2.5

Rectangle {
    id: menuRow
    property bool darkMode: false
    property string title: ""
    property string subtitle: ""
    property string marker: ""
    property bool highlighted: false
    signal clicked

    Theme { id: theme; darkMode: menuRow.darkMode }

    width: parent ? parent.width : implicitWidth
    height: Math.max(theme.buttonMinHeight, copyColumn.height + theme.spacingSmall * 2)
    radius: theme.cardRadius
    clip: true
    border.width: menuRow.highlighted ? 2 : 1
    border.color: menuRow.highlighted ? theme.accentBackground : theme.buttonBorder
    color: mouseArea.pressed
        ? theme.text
        : (menuRow.highlighted ? theme.accentBackground : theme.buttonBackground)

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: theme.sectionRailWidth
        color: menuRow.highlighted ? theme.accentText : theme.sectionRail
    }

    Column {
        id: copyColumn
        anchors.left: parent.left
        anchors.leftMargin: theme.spacingSmall + theme.sectionRailWidth
        anchors.right: markerText.visible ? markerText.left : parent.right
        anchors.rightMargin: theme.spacingSmall
        anchors.verticalCenter: parent.verticalCenter
        spacing: theme.spacingXs / 2

        Text {
            width: parent.width
            text: menuRow.title
            font.pixelSize: theme.fontButton
            font.bold: menuRow.highlighted
            elide: Text.ElideRight
            color: mouseArea.pressed
                ? theme.background
                : (menuRow.highlighted ? theme.accentText : theme.text)
        }

        Text {
            visible: menuRow.subtitle.length > 0
            width: parent.width
            text: menuRow.subtitle
            font.pixelSize: theme.fontSmall
            elide: Text.ElideRight
            color: mouseArea.pressed
                ? theme.background
                : (menuRow.highlighted ? theme.accentText : theme.textMuted)
        }
    }

    Text {
        id: markerText
        visible: menuRow.marker.length > 0
        anchors.right: parent.right
        anchors.rightMargin: theme.spacingSmall
        anchors.verticalCenter: parent.verticalCenter
        text: menuRow.marker
        font.pixelSize: theme.fontEyebrow
        font.bold: true
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 1.5
        color: mouseArea.pressed
            ? theme.background
            : (menuRow.highlighted ? theme.accentText : theme.textMuted)
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        enabled: menuRow.enabled
        onClicked: menuRow.clicked()
    }

    EinkRefreshArea {
        anchors.fill: parent
        displayMethod: mouseArea.pressed ? EinkRefreshArea.Fast : EinkRefreshArea.UI
    }
}
