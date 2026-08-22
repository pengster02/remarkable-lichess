import QtQuick 2.5
import QtQuick.Templates 2.5 as T

T.Button {
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
        radius: theme.compactControlRadius
        border.width: control.highlighted ? 2 : 1
        border.color: !control.enabled
            ? theme.cardBorder
            : (control.highlighted ? theme.accentBackground : theme.buttonBorder)
        color: !control.enabled
            ? theme.cardBackground
            : (control.pressed
            ? theme.text
            : (control.highlighted ? theme.accentBackground : theme.buttonBackground))
    }

    contentItem: Text {
        text: control.text
        font.pixelSize: theme.fontSmall
        font.bold: control.highlighted
        color: !control.enabled
            ? theme.textMuted
            : (control.pressed
            ? theme.background
            : (control.highlighted ? theme.accentText : theme.text))
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        fontSizeMode: Text.Fit
        minimumPixelSize: 22
        elide: Text.ElideRight
    }

    EinkRefreshArea {
        anchors.fill: parent
        displayMethod: control.pressed
            ? EinkRefreshArea.Fast
            : EinkRefreshArea.UI
    }
}
