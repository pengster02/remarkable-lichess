import QtQuick 2.5
import QtQuick.Controls 2.5 as QQC2

// Overrides every unqualified `TextField { ... }` in this directory app-wide,
// same same-directory-file-wins-over-imported-module resolution Button.qml
// already relies on for the same reason: QtQuick Controls' bare default
// "Basic" style chrome was completely disconnected from Theme, and (unlike
// Button.qml, which already got this treatment) every call site was also
// hand-picking its own literal pixel width (220/340/560) rather than reading
// from Theme, the exact kind of drift Theme.qml exists to prevent.
//
// The actual reason this file exists, though: QtQuick Controls' default
// cursorDelegate blinks via a looping opacity SequentialAnimation -- a real
// waveform update roughly every ~500ms for as long as any TextField has
// focus, on a display where that's a genuinely visible/costly refresh, not
// just wasted GPU cycles the way it would be on an LCD. A plain static
// Rectangle with no animation at all fixes that outright.
//
// Known limitation, same as Button.qml: uses Theme's default (light)
// instance rather than each screen's own darkMode, for the same reason
// (threading darkMode into every call site individually is a separate,
// larger change).
QQC2.TextField {
    id: control
    Theme { id: theme }
    font.pixelSize: theme.fontLarge
    color: theme.text
    placeholderTextColor: theme.textMuted
    width: theme.textFieldWidthMedium
    topPadding: theme.spacingSmall
    bottomPadding: theme.spacingSmall
    leftPadding: theme.spacingSmall
    rightPadding: theme.spacingSmall

    background: Rectangle {
        radius: theme.cardRadius
        border.width: 1
        border.color: control.activeFocus ? theme.accentBackground : theme.buttonBorder
        color: theme.cardBackground
    }

    cursorDelegate: Rectangle {
        width: 2
        color: theme.text
        visible: control.activeFocus
    }
}
