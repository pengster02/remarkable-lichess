import QtQuick 2.5

Column {
    id: confirmControl
    property string actionText: ""
    property string confirmText: ""
    property string cancelText: "Cancel"
    property string busyText: ""
    property bool busy: false
    property bool armed: false
    property bool prominent: false
    property bool critical: false
    signal confirmed()

    Theme { id: theme }

    spacing: theme.spacingXs

    function reset() {
        confirmControl.armed = false
    }

    onVisibleChanged: {
        if (!visible) reset()
    }

    AppButton {
        objectName: "confirmActionPrimary"
        width: parent.width
        text: confirmControl.busy
            ? confirmControl.busyText
            : (confirmControl.armed
                ? confirmControl.confirmText
                : confirmControl.actionText)
        highlighted: confirmControl.armed ? !confirmControl.critical : confirmControl.prominent
        critical: confirmControl.armed && confirmControl.critical
        enabled: !confirmControl.busy
        onClicked: {
            if (confirmControl.armed) {
                confirmControl.armed = false
                confirmControl.confirmed()
            } else {
                confirmControl.armed = true
            }
        }
    }

    AppButton {
        objectName: "confirmActionCancel"
        width: parent.width
        text: confirmControl.cancelText
        visible: confirmControl.armed
        onClicked: confirmControl.reset()
    }
}
