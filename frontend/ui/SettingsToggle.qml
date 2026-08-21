import QtQuick 2.5

Item {
    id: toggleRow
    property bool darkMode: false
    property string label: ""
    property bool value: false
    signal toggled
    width: parent ? parent.width : implicitWidth
    height: theme.touchTarget

    Theme { id: theme; darkMode: toggleRow.darkMode }

    Text {
        anchors.left: parent.left
        anchors.right: toggleButton.left
        anchors.rightMargin: theme.spacingSmall
        anchors.verticalCenter: parent.verticalCenter
        text: toggleRow.label
        font.pixelSize: theme.fontLabel
        color: theme.text
        elide: Text.ElideRight
    }

    Rectangle {
        id: toggleButton
        objectName: "settingsToggleButton"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: theme.touchTarget * 2
        height: theme.touchTarget
        radius: theme.pillRadius
        color: toggleRow.value ? theme.accentBackground : theme.buttonBackground
        border.width: 2
        border.color: toggleRow.value ? theme.accentBackground : theme.buttonBorder

        Text {
            anchors.left: toggleRow.value ? parent.left : switchKnob.right
            anchors.right: toggleRow.value ? switchKnob.left : parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: toggleRow.value ? "On" : "Off"
            font.pixelSize: theme.fontSmall
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            color: toggleRow.value ? theme.accentText : theme.textMuted
        }

        Rectangle {
            id: switchKnob
            width: parent.height - theme.spacingXs * 2
            height: width
            radius: width / 2
            anchors.verticalCenter: parent.verticalCenter
            x: toggleRow.value
                ? parent.width - width - theme.spacingXs
                : theme.spacingXs
            color: toggleRow.value ? theme.accentText : theme.textMuted
        }

        MouseArea {
            id: toggleMouse
            anchors.fill: parent
            onClicked: toggleRow.toggled()
        }

        EinkRefreshArea {
            anchors.fill: parent
            displayMethod: toggleMouse.pressed
                ? EinkRefreshArea.Fast
                : EinkRefreshArea.UI
        }
    }
}
