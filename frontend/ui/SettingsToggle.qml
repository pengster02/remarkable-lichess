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

    AppButton {
        id: toggleButton
        objectName: "settingsToggleButton"
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: theme.touchTarget * 2
        compact: true
        text: toggleRow.value ? "On" : "Off"
        highlighted: toggleRow.value
        onClicked: toggleRow.toggled()
    }
}
