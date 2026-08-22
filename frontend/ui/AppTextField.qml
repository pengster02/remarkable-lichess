import QtQuick 2.5
import QtQuick.Templates as T

// The explicit app-specific type name prevents Qt from falling back to its
// desktop-sized TextField. The static cursor also avoids periodic e-ink redraws.
T.TextField {
    id: control
    property bool darkMode: nearestDarkMode(parent)

    // reMarkable's numeric keyboard does not always expose a dismiss key.
    // A page-wide tap catcher or trusting the OS affordance were the alternatives.
    function dismissKeyboard() {
        control.focus = false
        Qt.inputMethod.hide()
    }

    function nearestDarkMode(item) {
        while (item) {
            if (item.hasOwnProperty("darkMode")) return item.darkMode
            item = item.parent
        }
        return false
    }

    Theme { id: theme; darkMode: control.darkMode }
    font.pixelSize: theme.fontLarge
    color: theme.text
    placeholderTextColor: theme.textMuted
    width: theme.textFieldWidthMedium
    implicitHeight: theme.touchTarget
    verticalAlignment: TextInput.AlignVCenter
    padding: theme.spacingSmall
    onAccepted: control.dismissKeyboard()

    background: Rectangle {
        radius: theme.controlRadius
        border.width: control.activeFocus ? 3 : 1
        border.color: control.activeFocus ? theme.accentBackground : theme.buttonBorder
        color: theme.buttonBackground
    }

    cursorDelegate: Rectangle {
        width: 2
        color: theme.text
        visible: control.activeFocus
    }
}
