import QtQuick 2.9

AppDialog {
    id: dialog
    objectName: "pgnExportDialog"
    title: "Export PGN"
    visible: false
    dismissOnBackground: !saving
    property var backendSender
    property var nextRequestId
    property string gameId: ""
    property int pendingRequestId: 0
    readonly property bool saving: pendingRequestId > 0
    property string savedPath: ""
    property string errorMessage: ""

    Theme { id: theme; darkMode: dialog.darkMode }
    Timer { id: retryDelay }

    Text {
        objectName: "pgnExportStatus"
        width: parent.width
        text: dialog.saving ? "Saving PGN…"
            : dialog.errorMessage ? dialog.errorMessage
            : dialog.savedPath ? "PGN saved"
            : "Save game " + dialog.gameId + " as a PGN file."
        font.pixelSize: theme.fontBody
        color: dialog.errorMessage && !dialog.saving ? theme.errorText : theme.text
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
    }

    Text {
        objectName: "pgnExportPath"
        width: parent.width
        visible: text.length > 0
        text: dialog.savedPath
        font.pixelSize: theme.fontSmall
        color: theme.textMuted
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }

    AppButton {
        objectName: "savePgnButton"
        width: parent.width
        visible: !dialog.saving
        enabled: !retryDelay.running
        highlighted: !dialog.savedPath
        text: retryDelay.running ? "Retry available shortly"
            : dialog.errorMessage ? "Retry"
            : dialog.savedPath ? "Export again" : "Save PGN"
        onClicked: dialog.requestSave()
    }

    footer: AppButton {
        objectName: "closePgnExportButton"
        width: parent.width
        text: dialog.saving ? "Cancel" : "Close"
        onClicked: dialog.dismissed()
    }

    onDismissed: {
        cancelPending()
        visible = false
    }

    function openFor(id, saveNow) {
        if (!id) return
        if (gameId !== id) {
            reset()
            gameId = id
        }
        visible = true
        if (saveNow && !savedPath) requestSave()
    }

    function requestSave() {
        if (!gameId || saving || retryDelay.running) return
        pendingRequestId = nextRequestId()
        errorMessage = ""
        backendSender({type: "RequestPgnExport", game_id: gameId, request_id: pendingRequestId})
    }

    function cancelPending() {
        if (!saving) return
        var requestId = pendingRequestId
        pendingRequestId = 0
        backendSender({type: "CancelPgnExport", request_id: requestId})
    }

    function reset() {
        cancelPending()
        visible = false
        gameId = ""
        savedPath = ""
        errorMessage = ""
    }

    function handleMessage(message) {
        if (!saving || message.request_id !== pendingRequestId || message.game_id !== gameId) return
        pendingRequestId = 0
        if (message.type === "PgnExported") {
            savedPath = message.path
        } else {
            errorMessage = message.message || "Could not save the PGN file."
            if (message.retry_after_ms > 0) {
                retryDelay.interval = message.retry_after_ms
                retryDelay.restart()
            }
        }
    }
}
