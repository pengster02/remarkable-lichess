import QtQuick 2.9

AppDialog {
    id: dialog
    objectName: "variationDialog"
    title: "Variations"
    pageByRow: true
    property var lines: []
    property var currentNode: null
    property string storageError: ""
    property bool canRetrySave: false
    signal selected(var nodeIndex)
    signal retrySave()

    Theme { id: theme; darkMode: dialog.darkMode }

    Text {
        width: parent.width
        text: dialog.storageError
        visible: text.length > 0
        font.pixelSize: theme.fontSmall
        color: theme.errorText
        wrapMode: Text.WordWrap
    }

    AppButton {
        objectName: "retrySavingVariationsButton"
        text: "Retry saving"
        width: parent.width
        visible: dialog.canRetrySave
        onClicked: dialog.retrySave()
    }

    MenuRow {
        objectName: "variationStartRow"
        title: "Starting position"
        highlighted: dialog.currentNode === null
        darkMode: dialog.darkMode
        onClicked: dialog.selected(null)
    }

    Repeater {
        model: dialog.lines
        MenuRow {
            objectName: "variationLine-" + modelData.nodeIndex
            required property var modelData
            title: modelData.label
            highlighted: dialog.currentNode === modelData.nodeIndex
            darkMode: dialog.darkMode
            onClicked: dialog.selected(modelData.nodeIndex)
        }
    }

    footer: AppButton {
        width: parent.width
        text: "Close"
        onClicked: dialog.dismissed()
    }
}
