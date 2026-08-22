import QtQuick 2.5

Rectangle {
    id: segmentedControl
    property bool darkMode: false
    property var options: []
    property string value: ""
    signal selected(string value)

    Theme { id: theme; darkMode: segmentedControl.darkMode }

    width: parent ? parent.width : implicitWidth
    height: theme.touchTarget
    radius: theme.compactControlRadius
    color: theme.buttonBackground
    border.width: 1
    border.color: theme.buttonBorder

    Row {
        anchors.fill: parent

        Repeater {
            model: segmentedControl.options

            Item {
                id: segment
                required property var modelData
                width: segmentedControl.width / segmentedControl.options.length
                height: segmentedControl.height

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    radius: theme.compactControlRadius - 4
                    color: segmentedControl.value === segment.modelData.id
                        ? theme.accentBackground
                        : "transparent"
                }

                Text {
                    anchors.fill: parent
                    text: segment.modelData.label
                    font.pixelSize: theme.fontLabel
                    font.bold: segmentedControl.value === segment.modelData.id
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    color: segmentedControl.value === segment.modelData.id
                        ? theme.accentText
                        : theme.text
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: segmentedControl.selected(segment.modelData.id)
                }
            }
        }
    }

    EinkRefreshArea {
        anchors.fill: parent
        displayMethod: EinkRefreshArea.UI
    }
}
