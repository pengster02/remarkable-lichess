import QtQuick 2.5
import QtQuick.Controls 2.5 as QQC2

QQC2.Button {
    id: control
    property bool darkMode: nearestDarkMode(parent)

    function nearestDarkMode(item) {
        while (item) {
            if (item.hasOwnProperty("darkMode")) return item.darkMode
            item = item.parent
        }
        return false
    }

    Theme { id: theme; darkMode: control.darkMode }
    height: theme.touchTarget
    padding: 4

    background: Rectangle {
        radius: theme.cardRadius
        border.width: control.highlighted ? 3 : 1
        border.color: control.highlighted ? theme.accentBackground : theme.buttonBorder
        color: control.pressed
            ? theme.text
            : (control.highlighted ? theme.accentBackground : theme.buttonBackground)
        opacity: control.enabled ? 1.0 : 0.45
    }

    contentItem: Text {
        text: control.text
        font.pixelSize: theme.fontSmall
        font.bold: control.highlighted
        color: control.pressed
            ? theme.background
            : (control.highlighted ? theme.accentText : theme.text)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        fontSizeMode: Text.Fit
        minimumPixelSize: 22
        elide: Text.ElideRight
        opacity: control.enabled ? 1.0 : 0.45
    }

    EinkRefreshArea {
        anchors.fill: parent
        displayMethod: control.pressed
            ? EinkRefreshArea.Fast
            : EinkRefreshArea.UI
    }
}
