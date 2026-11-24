import QtQuick 2.5

Rectangle {
    id: loginScreen
    anchors.fill: parent
    color: theme.background
    Theme { id: theme; darkMode: loginScreen.darkMode }
    property var backendSender
    property var nextRequestId
    property bool darkMode: false

    property string phase: "starting"
    property int signInRequestId: 0
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
    readonly property bool manualPending: manualEntry && (phase === "verifying" || phase === "committing")

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
        if (loginScreen.backendSender && loginScreen.nextRequestId && loginScreen.signInRequestId === 0) {
            loginScreen.startLogin()
        }
    }
    onNextRequestIdChanged: {
        if (loginScreen.backendSender && loginScreen.nextRequestId && loginScreen.signInRequestId === 0) {
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
                    enabled: loginScreen.phase !== "committing"
                    onClicked: loginScreen.showManualEntry()
                }
            }

            SectionCard {
                objectName: "tokenCard"
                darkMode: loginScreen.darkMode
                title: "Personal access token"
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
                    echoMode: TextInput.Password
                    inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText
                    readOnly: loginScreen.manualPending
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
                    objectName: "saveTokenButton"
                    width: parent.width
                    text: loginScreen.manualPending ? "Verifying token…" : "Save"
                    enabled: !loginScreen.manualPending
                    highlighted: true
                    onClicked: loginScreen.saveToken()
                }

                AppButton {
                    objectName: "backToScanButton"
                    width: parent.width
                    text: "Scan a code instead"
                    enabled: loginScreen.phase !== "committing"
                    onClicked: loginScreen.startLogin()
                }
            }
        }
    }

    function statusText() {
        if (loginScreen.phase === "starting") return "Preparing a sign-in code..."
        if (loginScreen.phase === "verifying" || loginScreen.phase === "committing") return "Signing you in..."
        if (loginScreen.phase === "failed") return loginScreen.errorMessage
        return "Scan to sign in"
    }

    function startLogin() {
        if (!loginScreen.backendSender || !loginScreen.nextRequestId || loginScreen.phase === "committing") return
        loginScreen.dismissKeyboard()
        loginScreen.manualEntry = false
        loginScreen.phase = "starting"
        loginScreen.errorMessage = ""
        loginScreen.qrRows = []
        loginScreen.qrModules = 0
        loginScreen.authorizeUrl = ""
        tokenField.text = ""
        loginScreen.signInRequestId = loginScreen.nextRequestId()
        loginScreen.backendSender({type: "StartLogin", request_id: loginScreen.signInRequestId})
    }

    // Stops the backend holding its callback port open for a sign-in nobody is
    // going to finish.
    function showManualEntry() {
        if (loginScreen.manualEntry || loginScreen.phase === "committing") return
        loginScreen.dismissKeyboard()
        var request = loginScreen.signInRequestId
        loginScreen.signInRequestId = 0
        loginScreen.phase = "idle"
        loginScreen.errorMessage = ""
        loginScreen.manualEntry = true
        if (request > 0) loginScreen.backendSender({type: "CancelLogin", request_id: request})
    }

    function saveToken() {
        if (!loginScreen.manualEntry || loginScreen.manualPending) return
        loginScreen.dismissKeyboard()
        var token = tokenField.text.trim()
        if (token.length === 0) {
            loginScreen.errorMessage = "Enter a personal access token."
            return
        }
        loginScreen.errorMessage = ""
        loginScreen.phase = "verifying"
        loginScreen.signInRequestId = loginScreen.nextRequestId()
        loginScreen.backendSender({type: "SaveToken", token: token, request_id: loginScreen.signInRequestId})
    }

    function acceptsCommittedSignIn(msg) {
        return loginScreen.phase === "committing" &&
            loginScreen.signInRequestId > 0 && msg.request_id === loginScreen.signInRequestId
    }

    function handleMessage(msg) {
        if (msg.type === "TokenInvalid") {
            loginScreen.errorMessage = msg.reason || "Lichess rejected the sign-in."
            return
        }
        if (loginScreen.signInRequestId === 0 || msg.request_id !== loginScreen.signInRequestId) return
        if (msg.type === "LoginChallenge") {
            if (loginScreen.manualEntry || loginScreen.phase !== "starting") return
            loginScreen.authorizeUrl = msg.authorize_url || ""
            loginScreen.qrRows = msg.qr_rows || []
            loginScreen.qrModules = msg.qr_size || 0
            loginScreen.errorMessage = ""
            loginScreen.phase = "ready"
        } else if (msg.type === "LoginVerifying") {
            if (loginScreen.manualEntry || loginScreen.phase !== "ready") return
            loginScreen.phase = "verifying"
        } else if (msg.type === "SignInReady") {
            if (loginScreen.phase !== "verifying") return
            loginScreen.phase = "committing"
            loginScreen.backendSender({type: "CompleteSignIn", request_id: loginScreen.signInRequestId})
        } else if (msg.type === "LoginFailed") {
            loginScreen.errorMessage = msg.reason || "Sign-in failed"
            loginScreen.phase = "failed"
            loginScreen.signInRequestId = 0
        }
    }
}
