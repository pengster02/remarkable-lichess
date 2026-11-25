import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    id: testCase
    name: "SeekScreen"
    when: windowShown
    visible: true
    width: 960
    height: 1696

    property var sentMessages: []
    property int requestSequence: 0

    SeekScreen {
        id: seek
        width: 960
        height: 1696
        backendSender: function(message) { testCase.sentMessages.push(message) }
        nextRequestId: function() { return ++testCase.requestSequence }
        navigateTo: function() {}
    }

    function init() {
        sentMessages = []
        seek.pendingAction = ""
        seek.formError = ""
        seek.selectedColor = "random"
        seek.openChallengeUrls = null
        seek.clearWaiting()
        seek.seekEnded = false
        findChild(seek, "minutesField").text = "10"
        findChild(seek, "incrementField").text = "0"
        findChild(seek, "usernameField").text = ""
        findChild(seek, "aiLevelField").text = "3"
        seek.dismissKeyboard()
    }

    function test_doneTypingClearsFieldFocus() {
        var minutes = findChild(seek, "minutesField")
        var done = findChild(seek, "timeKeyboardDoneButton")
        verify(minutes !== null)
        verify(done !== null)

        minutes.forceActiveFocus()
        verify(seek.keyboardActive)
        verify(done.editing)
        done.clicked()

        verify(!minutes.activeFocus)
        verify(!seek.keyboardActive)
        minutes.clear()
        verify(!findChild(minutes, "textFieldPlaceholder").visible)
    }

    function test_pageNavigationDismissesTheKeyboard() {
        var username = findChild(seek, "usernameField")
        var pager = findChild(seek, "seekFlickable")
        username.forceActiveFocus()
        verify(seek.keyboardActive)
        pager.pageUp()
        verify(!seek.keyboardActive)
    }

    function test_secondPageBeginsAtPlayerChallenge() {
        var pager = findChild(seek, "seekFlickable")
        var challenge = findChild(seek, "playerChallengeSection")
        verify(pager !== null)
        verify(challenge !== null)
        tryCompare(pager, "pageCount", 2)
        pager.moveTo(0)
        pager.pageDown()
        tryCompare(pager, "currentPage", 2)
        fuzzyCompare(pager.contentY, challenge.y, 1)
        fuzzyCompare(challenge.mapToItem(pager, 0, 0).y, 0, 1)
    }

    function test_timeControlUsesExplicitUnits() {
        var summary = findChild(seek, "timeControlSummary")
        verify(summary !== null)
        compare(summary.text, "10 minutes + 0 seconds per move")

        findChild(seek, "minutesField").text = "1"
        findChild(seek, "incrementField").text = "1"
        compare(summary.text, "1 minute + 1 second per move")
        verify(findChild(seek, "minutesField").height >= 96)
        verify(findChild(seek, "incrementField").height >= 96)
    }

    function test_invalidTimeNeverLeavesTheDevice() {
        findChild(seek, "minutesField").text = "ten"
        seek.submitSeek()
        compare(sentMessages.length, 0)
        compare(seek.pendingAction, "")
        compare(seek.formError, "Minutes must be a whole number.")

        findChild(seek, "minutesField").text = "0"
        findChild(seek, "incrementField").text = "0"
        seek.submitSeek()
        compare(sentMessages.length, 0)
        verify(seek.formError.length > 0)
    }

    function test_incrementLimitMatchesTheChosenAction() {
        findChild(seek, "minutesField").text = "1"
        findChild(seek, "incrementField").text = "120"
        seek.submitSeek()
        compare(sentMessages.length, 1)
        compare(sentMessages[0].type, "CreateSeek")

        seek.pendingAction = ""
        sentMessages = []
        findChild(seek, "usernameField").text = "opponent"
        seek.submitChallenge()
        compare(sentMessages.length, 0)
        compare(seek.formError, "Increment must be between 0 and 60.")
    }

    function test_challengeRequiresAUsername() {
        var pager = findChild(seek, "seekFlickable")
        var section = findChild(seek, "playerChallengeSection")
        var error = findChild(seek, "seekErrorText")
        var back = findChild(seek, "matchBackButton")
        pager.moveTo(section.y)
        var offset = pager.contentY
        verify(offset > 0)

        seek.submitChallenge()
        compare(sentMessages.length, 0)
        compare(seek.formError, "Enter the Lichess username you want to challenge.")
        tryVerify(function() { return error.visible && error.y >= pager.y + pager.height })
        verify(error.y + error.height <= back.y)
        compare(pager.contentY, offset)

        var username = findChild(seek, "usernameField")
        username.forceActiveFocus()
        verify(seek.keyboardActive)
        username.text = "opponent"
        verify(!error.visible)
        seek.submitChallenge()
        verify(!seek.keyboardActive)
        compare(sentMessages.length, 1)
        compare(sentMessages[0].type, "CreateChallenge")
        compare(sentMessages[0].username, "opponent")
    }

    function test_pendingRequestBlocksDuplicateSubmissionsAndRecovers() {
        seek.submitSeek()
        seek.submitSeek()
        compare(sentMessages.length, 1)
        compare(seek.pendingAction, "seek")
        compare(findChild(seek, "findOpponentButton").enabled, false)

        seek.handleMessage({type: "SeekFailed", request_id: sentMessages[0].request_id,
                            message: "Rate limited"})
        compare(seek.pendingAction, "")
        compare(seek.formError, "Rate limited")
        compare(findChild(seek, "findOpponentButton").enabled, true)
    }

    function test_endedSeekCanStartAgain() {
        seek.seekEnded = true
        findChild(seek, "findOpponentButton").clicked()
        compare(sentMessages.length, 1)
        compare(sentMessages[0].type, "CreateSeek")
        verify(!seek.seekEnded)
    }

    function test_openChallengeReplyClearsPendingAndShowsLinks() {
        seek.submitOpenChallenge()
        compare(seek.pendingAction, "open")
        seek.handleMessage({
            type: "OpenChallengeCreated",
            request_id: sentMessages[0].request_id,
            url: "https://lichess.org/open",
            url_white: "https://lichess.org/white",
            url_black: "https://lichess.org/black"
        })
        compare(seek.pendingAction, "")
        compare(seek.formError, "")
        compare(seek.openChallengeUrls.url_white, "https://lichess.org/white")
        compare(findChild(seek, "openChallengeUrl").text, "https://lichess.org/open")
        verify(!findChild(seek, "openChallengeQr").visible)
        findChild(seek, "openChallengeSide").selected("black")
        compare(findChild(seek, "openChallengeUrl").text, "https://lichess.org/black")
    }

    function test_computerLevelIsValidatedBeforeSending() {
        findChild(seek, "aiLevelField").text = "9"
        seek.submitComputerGame()
        compare(sentMessages.length, 0)
        compare(seek.formError, "Computer level must be a whole number from 1 to 8.")

        findChild(seek, "aiLevelField").text = "8"
        seek.selectedColor = "black"
        seek.submitComputerGame()
        compare(sentMessages.length, 1)
        compare(sentMessages[0].type, "ChallengeAi")
        compare(sentMessages[0].level, 8)
        compare(sentMessages[0].color, "black")
    }
}
