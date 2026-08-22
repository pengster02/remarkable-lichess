import QtQuick 2.5

AppButton {
    id: control
    property bool editing: false
    signal dismissRequested()

    visible: control.editing || control.pressed
    focusPolicy: Qt.NoFocus
    compact: true
    text: "Done typing"
    onClicked: control.dismissRequested()
}
