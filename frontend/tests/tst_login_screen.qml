import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "LoginScreen"
    when: windowShown
    width: 960
    height: 1696

    property var sent: []

    Theme {
        id: theme
    }

    // Declared here rather than built with createTemporaryQmlObject: an inline
    // QML string is compiled against the QtTest module's own directory, where
    // the relative "../ui" import doesn't resolve.
    Component {
        id: freshLogin
        LoginScreen {
            width: 400
            height: 800
        }
    }

    LoginScreen {
        id: login
        width: 960
        height: 1696
        backendSender: function(msg) { sent.push(msg) }
    }

    function challenge(size) {
        var rows = []
        for (var y = 0; y < size; ++y) {
            var row = ""
            for (var x = 0; x < size; ++x) {
                row += ((x + y) % 2 === 0) ? "1" : "0"
            }
            rows.push(row)
        }
        return {
            type: "LoginChallenge",
            authorize_url: "https://lichess.org/oauth?response_type=code&client_id=remarkable-lichess",
            qr_size: size,
            qr_rows: rows,
            expires_in_secs: 300
        }
    }

    function init() {
        login.darkMode = false
        login.startLogin()
        sent = []
    }

    function test_asksForAChallengeWithoutAnyTapping() {
        // The entry screen has to start the flow itself -- nothing else in the
        // app is around to send StartLogin on its behalf.
        var fresh = []
        var screen = createTemporaryObject(freshLogin, login)
        verify(screen !== null)
        screen.backendSender = function(msg) { fresh.push(msg) }
        compare(fresh.length, 1)
        compare(fresh[0].type, "StartLogin")
    }

    function test_challengeRendersAScannableQr() {
        login.handleMessage(challenge(33))
        compare(login.phase, "ready")
        verify(login.showingQr)
        var qr = findChild(login, "loginQrCode")
        verify(qr !== null)
        compare(qr.moduleCount, 33)
        // Quiet zone on both sides, or scanners can't find the symbol's edges.
        compare(qr.totalModules, 33 + qr.quietZone * 2)
        // Whole-pixel modules: any fractional size anti-aliases every edge into
        // greys this panel renders as mush.
        compare(qr.moduleSize, Math.floor(qr.moduleSize))
        verify(qr.moduleSize >= 1)
        compare(qr.width, qr.moduleSize * qr.totalModules)
        compare(qr.width, qr.height)
    }

    // The matrix is only as good as where it lands on screen: this pins the
    // quiet-zone offset and the per-module scale against the painted pixels.
    // The synthetic matrix is a checkerboard starting dark at (0,0).
    function test_modulesLandOnWholePixelsInsideTheQuietZone() {
        login.handleMessage(challenge(21))
        var qr = findChild(login, "loginQrCode")
        var m = qr.moduleSize
        var quiet = qr.quietZone * m
        var spans = qr.darkSpans()
        verify(spans.length > 0)

        // The synthetic matrix is a checkerboard starting dark at (0,0), so
        // every dark run is a single module and the first one sits exactly at
        // the quiet-zone corner.
        compare(spans[0].x, quiet)
        compare(spans[0].y, quiet)
        compare(spans[0].width, m)
        compare(spans[0].height, m)

        for (var i = 0; i < spans.length; ++i) {
            var span = spans[i]
            // Nothing may spill into the quiet zone or past the far edge.
            verify(span.x >= quiet)
            verify(span.y >= quiet)
            verify(span.x + span.width <= quiet + 21 * m)
            verify(span.y + span.height <= quiet + 21 * m)
            // Whole modules only -- a half-module offset is what makes the
            // canvas anti-alias edges into unscannable grey.
            compare((span.x - quiet) % m, 0)
            compare((span.y - quiet) % m, 0)
            compare(span.width % m, 0)
        }
    }

    function test_adjacentDarkModulesMergeIntoOneFill() {
        var solid = {
            type: "LoginChallenge", authorize_url: "https://lichess.org/oauth",
            qr_size: 4, qr_rows: ["1111", "0000", "1100", "1011"], expires_in_secs: 300
        }
        login.handleMessage(solid)
        var qr = findChild(login, "loginQrCode")
        var m = qr.moduleSize
        var quiet = qr.quietZone * m
        var spans = qr.darkSpans()
        // Row 0 is one run of 4, row 1 none, row 2 one run of 2, row 3 two runs.
        compare(spans.length, 4)
        compare(spans[0].width, 4 * m)
        compare(spans[0].y, quiet)
        compare(spans[1].width, 2 * m)
        compare(spans[1].y, quiet + 2 * m)
        compare(spans[2].width, 1 * m)
        compare(spans[3].width, 2 * m)
    }

    function test_qrStaysDarkOnLightInDarkMode() {
        login.darkMode = true
        login.handleMessage(challenge(21))
        var plate = findChild(login, "qrPlate")
        verify(plate !== null)
        compare(plate.color, Qt.rgba(1, 1, 1, 1))
        var qr = findChild(login, "loginQrCode")
        compare(qr.darkColor, Qt.rgba(0, 0, 0, 1))
        compare(qr.lightColor, Qt.rgba(1, 1, 1, 1))
    }

    function test_urlIsOfferedForDevicesWithoutACamera() {
        login.handleMessage(challenge(21))
        verify(login.showingUrl)
        var urlText = findChild(login, "authorizeUrlText")
        verify(urlText !== null)
        verify(urlText.text.indexOf("lichess.org/oauth") !== -1)
    }

    function test_failureExplainsItselfAndOffersARetry() {
        login.handleMessage({type: "LoginFailed", reason: "this reMarkable isn't on a Wi-Fi network yet"})
        compare(login.phase, "failed")
        verify(!login.showingQr)
        verify(login.showingRetry)
        verify(login.statusText().indexOf("Wi-Fi") !== -1)
        var retry = findChild(login, "retryLoginButton")
        verify(retry !== null)
        compare(retry.text, "Try again")
        retry.clicked()
        compare(sent.length, 1)
        compare(sent[0].type, "StartLogin")
        compare(login.phase, "starting")
    }

    function test_switchingToTokenEntryReleasesTheCallbackPort() {
        login.handleMessage(challenge(21))
        var manual = findChild(login, "manualEntryButton")
        verify(manual !== null)
        manual.clicked()
        compare(sent.length, 1)
        compare(sent[0].type, "CancelLogin")
        verify(login.showingTokenEntry)
        verify(!login.showingQr)
    }

    function test_doneTypingDismissesManualTokenKeyboard() {
        login.showManualEntry()
        sent = []
        var token = findChild(login, "tokenField")
        var done = findChild(login, "tokenKeyboardDoneButton")
        verify(token !== null)
        verify(done !== null)

        token.forceActiveFocus()
        verify(login.keyboardActive)
        verify(done.editing)
        done.clicked()
        verify(!login.keyboardActive)
    }

    function test_rejectedTokenSurfacesTheReason() {
        login.handleMessage({type: "TokenInvalid", reason: "Unauthorized"})
        compare(login.phase, "failed")
        verify(login.errorMessage.indexOf("Unauthorized") !== -1)
    }

    function test_completedSignInShowsProgressRatherThanTheQr() {
        login.handleMessage(challenge(21))
        login.handleMessage({type: "LoginCompleted"})
        compare(login.phase, "verifying")
        verify(!login.showingQr)
        verify(login.statusText().indexOf("Signing you in") !== -1)
    }

    function test_startingOverClearsTheExpiredCode() {
        login.handleMessage(challenge(21))
        login.startLogin()
        compare(login.phase, "starting")
        compare(login.qrModules, 0)
        compare(login.authorizeUrl, "")
        verify(!login.showingQr)
    }
}
