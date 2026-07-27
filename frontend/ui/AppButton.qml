import QtQuick 2.5
import QtQuick.Controls 2.5 as QQC2

// Uses an explicit app-specific type name so Qt cannot resolve call sites to
// QtQuick Controls' desktop-sized Button instead.
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
    font.pixelSize: theme.fontButton
    topPadding: theme.buttonPaddingV
    bottomPadding: theme.buttonPaddingV
    leftPadding: theme.buttonPaddingH
    rightPadding: theme.buttonPaddingH
    // Real height/width, not implicitHeight/implicitWidth: Control's C++
    // side recomputes implicit size from contentItem+padding on its own and
    // silently clears any QML binding on it, throwing away this floor.
    height: Math.max(contentItem.implicitHeight + topPadding + bottomPadding, theme.buttonMinHeight)
    width: Math.max(contentItem.implicitWidth + leftPadding + rightPadding, theme.touchTarget * 2)

    background: Rectangle {
        radius: theme.cardRadius
        border.width: control.highlighted ? 3 : 1
        border.color: control.highlighted ? theme.accentBackground : theme.buttonBorder
        // Pressed = full color inversion, not a tint -- more visible at
        // e-ink refresh latency than a subtle mid-tone shift.
        color: control.pressed
            ? theme.text
            : (control.highlighted ? theme.accentBackground : theme.buttonBackground)
        // Disabled buttons previously looked identical to enabled ones --
        // a dead tap with no feedback read as "the app froze."
        opacity: control.enabled ? 1.0 : 0.45

    }

    contentItem: Text {
        text: control.text
        font: control.font
        color: control.pressed
            ? theme.background
            : (control.highlighted ? theme.accentText : theme.text)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        opacity: control.enabled ? 1.0 : 0.45
    }
}
