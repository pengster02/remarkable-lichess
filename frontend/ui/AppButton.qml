import QtQuick 2.5
import QtQuick.Templates 2.5 as T

// Uses an explicit app-specific type name so Qt cannot resolve call sites to
// QtQuick Controls' desktop-sized Button instead.
// Templates skip platform-style objects entirely. Explicit Basic style and a
// qtquickcontrols2.conf style lock were the next-best options, but both retain
// a style layer this fully drawn control does not use.
T.Button {
    id: control
    property bool darkMode: nearestDarkMode(parent)
    property bool critical: false
    // Dialog-level density avoids duplicated call-site flags; separate dialog
    // buttons would split one interaction system, while global compactness is too broad.
    property bool compact: nearestDenseActions(parent)
    property int textAlignment: Text.AlignHCenter
    property real cornerRadius: control.compact
        ? theme.compactControlRadius
        : theme.controlRadius

    function nearestDarkMode(item) {
        while (item) {
            if (item.hasOwnProperty("darkMode")) return item.darkMode
            item = item.parent
        }
        return false
    }

    function nearestDenseActions(item) {
        while (item) {
            if (item.hasOwnProperty("denseActions")) return item.denseActions
            item = item.parent
        }
        return false
    }

    Theme { id: theme; darkMode: control.darkMode }
    font.pixelSize: control.compact ? theme.fontLabel : theme.fontButton
    font.bold: control.highlighted || control.critical
    topPadding: control.compact ? theme.spacingXs : theme.buttonPaddingV
    bottomPadding: control.compact ? theme.spacingXs : theme.buttonPaddingV
    leftPadding: control.compact ? theme.spacingSmall : theme.buttonPaddingH
    rightPadding: control.compact ? theme.spacingSmall : theme.buttonPaddingH
    // Width the label actually needs. Call sites that override `width` must
    // keep this as their floor, or the text renders outside the background.
    readonly property real naturalWidth: contentItem.implicitWidth + leftPadding + rightPadding

    // Real height/width, not implicitHeight/implicitWidth: Control's C++
    // side recomputes implicit size from contentItem+padding on its own and
    // silently clears any QML binding on it, throwing away this floor.
    height: control.compact
        ? theme.touchTarget
        : Math.max(contentItem.implicitHeight + topPadding + bottomPadding, theme.buttonMinHeight)
    width: Math.max(control.naturalWidth, theme.touchTarget * 2)

    background: Rectangle {
        radius: control.cornerRadius
        border.width: control.highlighted || control.critical ? 2 : 1
        border.color: !control.enabled
            ? theme.cardBorder
            : (control.critical
            ? theme.criticalBackground
            : (control.highlighted ? theme.accentBackground : theme.buttonBorder))
        // Pressed = full color inversion, not a tint -- more visible at
        // e-ink refresh latency than a subtle mid-tone shift.
        color: !control.enabled
            ? theme.cardBackground
            : (control.pressed
            ? theme.text
            : (control.critical
                ? theme.criticalBackground
                : (control.highlighted ? theme.accentBackground : theme.buttonBackground)))
    }

    contentItem: Text {
        text: control.text
        font: control.font
        color: !control.enabled
            ? theme.textMuted
            : (control.pressed
            ? theme.background
            : (control.critical
                ? theme.criticalText
                : (control.highlighted ? theme.accentText : theme.text)))
        horizontalAlignment: control.textAlignment
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }

    EinkRefreshArea {
        anchors.fill: parent
        displayMethod: control.pressed
            ? EinkRefreshArea.Fast
            : EinkRefreshArea.UI
    }
}
