import QtQuick 2.5

Column {
    id: confirmControl
    property string actionText: ""
    property string confirmText: ""
    property string cancelText: "Cancel"
    property string busyText: ""
    property bool busy: false
    property bool prominent: false
    property bool critical: false
    // When true, needs one extra confirmation tap (arm -> confirm -> confirm
    // again) -- resign/abort opt into this via BoardScreen.confirmResign / the
    // Settings "Confirm resign / abort" toggle. Off = the normal two-tap.
    property bool extraConfirm: false
    property int armLevel: 0
    readonly property bool armed: confirmControl.armLevel > 0
    signal confirmed()

    Theme { id: theme }

    spacing: theme.spacingXs

    function reset() {
        confirmControl.armLevel = 0
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
            var needed = confirmControl.extraConfirm ? 2 : 1
            if (confirmControl.armLevel >= needed) {
                confirmControl.armLevel = 0
                confirmControl.confirmed()
            } else {
                confirmControl.armLevel += 1
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
