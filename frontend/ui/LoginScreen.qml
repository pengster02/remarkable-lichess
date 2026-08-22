import QtQuick 2.5

Rectangle {
    id: loginScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: loginScreen.darkMode }
    property var backendSender
    property bool darkMode: false

    // Screen state, driven entirely by backend replies (see protocol.rs's
    // LoginChallenge/LoginCompleted/LoginFailed). "starting" is the initial
    // value because this screen asks for a challenge the moment it appears.
    property string phase: "starting"
    property string authorizeUrl: ""
    property var qrRows: []
    property int qrModules: 0
    property string errorMessage: ""
    property bool manualEntry: false

    // What the screen is showing, named once here instead of repeating the
    // phase comparisons inline on each `visible:` binding. Also the only
    // handle a test has on this: Qt reports every item's effective visibility
    // as false under the offscreen test runner, so asserting on `visible`
    // itself would prove nothing.
    readonly property bool showingQr: !manualEntry && phase === "ready" && qrModules > 0
    readonly property bool showingRetry: !manualEntry && (phase === "failed" || phase === "ready")
    readonly property bool showingUrl: showingQr && authorizeUrl.length > 0
    readonly property bool showingTokenEntry: manualEntry
    readonly property bool keyboardActive: tokenField.activeFocus

    function dismissKeyboard() {
        tokenField.focus = false
        loginScreen.forceActiveFocus()
        Qt.inputMethod.hide()
    }

    // Not Component.onCompleted: backendSender isn't assigned yet at that point
    // (main.qml's Loader.onLoaded runs after the item is constructed -- see
    // GameHistoryScreen's note on the same hazard). This screen is the app's
    // entry point, so nothing else is around to kick the flow off for it.
    onBackendSenderChanged: {
        if (loginScreen.backendSender) {
            loginScreen.startLogin()
        }
    }

    EinkPagedFlickable {
        anchors.fill: parent
        anchors.margins: theme.pageSideMargin
        anchors.topMargin: theme.pageTopMargin
        contentHeight: loginColumn.height
        onPageNavigationRequested: loginScreen.dismissKeyboard()

        Column {
            id: loginColumn
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: theme.spacingMedium
            width: parent.width * 0.85

            AppPageHeader {
                width: parent.width
                darkMode: loginScreen.darkMode
                eyebrow: "Welcome"
                title: "Lichess"
                detail: "Chess, made for paper"
                pieceSource: "../assets/pieces/cburnett/wK.png"
            }

            SectionCard {
                objectName: "signInCard"
                darkMode: loginScreen.darkMode
                title: "Sign in"
                width: parent.width
                visible: !loginScreen.showingTokenEntry

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    horizontalAlignment: Text.AlignHCenter
                    text: loginScreen.statusText()
                    font.pixelSize: theme.fontBody
                    color: loginScreen.phase === "failed" ? theme.errorText : theme.text
                }

                // Always black on white, never themed: scanners expect dark
                // modules on a light field, and inverting it in dark mode is a
                // decoding risk for no benefit on a screen that never glows.
                Rectangle {
                    objectName: "qrPlate"
                    visible: loginScreen.showingQr
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: qrImage.width
                    height: qrImage.height
                    color: "#ffffff"

                    QrCode {
                        id: qrImage
                        objectName: "loginQrCode"
                        rows: loginScreen.qrRows
                        moduleCount: loginScreen.qrModules
                        targetSize: Math.min(520, loginColumn.width - theme.spacingSmall * 2)
                    }
                }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    visible: loginScreen.showingQr
                    text: "Scan with your phone and approve on lichess.org. Your phone has to be on the same Wi-Fi as this tablet — it sends the answer straight back here, so Lichess will note that last hop isn't encrypted. Nothing leaves your local network."
                    font.pixelSize: theme.fontSmall
                    color: theme.textMuted
                }

                Text {
                    objectName: "authorizeUrlText"
                    width: parent.width
                    wrapMode: Text.WrapAnywhere
                    visible: loginScreen.showingUrl
                    text: "No camera? Open this on any device on this network:\n" + loginScreen.authorizeUrl
                    font.pixelSize: theme.fontSmall
                    color: theme.textMuted
                }

                AppButton {
                    objectName: "retryLoginButton"
                    width: parent.width
                    visible: loginScreen.showingRetry
                    text: loginScreen.phase === "failed" ? "Try again" : "Start over"
                    highlighted: loginScreen.phase === "failed"
                    onClicked: loginScreen.startLogin()
                }

                AppButton {
                    objectName: "manualEntryButton"
                    width: parent.width
                    text: "Enter a token instead"
                    onClicked: loginScreen.showManualEntry()
                }
            }

            SectionCard {
                objectName: "tokenCard"
                darkMode: loginScreen.darkMode
                title: "Sign in with a personal access token"
                width: parent.width
                visible: loginScreen.showingTokenEntry

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "Generate one at lichess.org/account/oauth/token with the board:play, challenge:read, challenge:write, and preference:read scopes, then paste it below."
                    font.pixelSize: theme.fontSmall
                    color: theme.textMuted
                }

                AppTextField {
                    id: tokenField
                    objectName: "tokenField"
                    width: parent.width
                    font.pixelSize: theme.fontLarge
                    placeholderText: "lip_..."
                    Keys.onReturnPressed: loginScreen.saveToken()
                    Keys.onEnterPressed: loginScreen.saveToken()
                }

                KeyboardDismissButton {
                    objectName: "tokenKeyboardDoneButton"
                    width: parent.width
                    editing: tokenField.activeFocus
                    onDismissRequested: loginScreen.dismissKeyboard()
                }

                Text {
                    objectName: "tokenErrorText"
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: theme.errorText
                    font.pixelSize: theme.fontLabel
                    visible: loginScreen.manualEntry && loginScreen.errorMessage.length > 0
                    text: loginScreen.errorMessage
                }

                AppButton {
                    width: parent.width
                    text: "Save"
                    highlighted: true
                    onClicked: loginScreen.saveToken()
                }

                AppButton {
                    objectName: "backToScanButton"
                    width: parent.width
                    text: "Scan a code instead"
                    onClicked: loginScreen.startLogin()
                }
            }
        }
    }

    function statusText() {
        if (loginScreen.phase === "starting") return "Preparing a sign-in code..."
        if (loginScreen.phase === "verifying") return "Signing you in..."
        if (loginScreen.phase === "failed") return loginScreen.errorMessage
        return "Scan to sign in"
    }

    function startLogin() {
        if (!loginScreen.backendSender) {
            return
        }
        loginScreen.dismissKeyboard()
        loginScreen.manualEntry = false
        loginScreen.phase = "starting"
        loginScreen.errorMessage = ""
        loginScreen.qrRows = []
        loginScreen.qrModules = 0
        loginScreen.authorizeUrl = ""
        loginScreen.backendSender({type: "StartLogin"})
    }

    // Stops the backend holding its callback port open for a sign-in nobody is
    // going to finish.
    function showManualEntry() {
        loginScreen.dismissKeyboard()
        loginScreen.backendSender({type: "CancelLogin"})
        loginScreen.errorMessage = ""
        loginScreen.manualEntry = true
    }

    function saveToken() {
        loginScreen.dismissKeyboard()
        loginScreen.errorMessage = ""
        loginScreen.backendSender({type: "SaveToken", token: tokenField.text})
    }

    function handleMessage(msg) {
        if (msg.type === "LoginChallenge") {
            loginScreen.authorizeUrl = msg.authorize_url || ""
            loginScreen.qrRows = msg.qr_rows || []
            loginScreen.qrModules = msg.qr_size || 0
            loginScreen.errorMessage = ""
            loginScreen.phase = "ready"
        } else if (msg.type === "LoginCompleted") {
            loginScreen.phase = "verifying"
        } else if (msg.type === "LoginFailed") {
            loginScreen.errorMessage = msg.reason || "Sign-in failed"
            loginScreen.phase = "failed"
        } else if (msg.type === "TokenInvalid") {
            loginScreen.errorMessage = "Token rejected: " + msg.reason
            loginScreen.phase = "failed"
        }
    }
}
