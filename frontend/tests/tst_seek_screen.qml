import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    id: testCase
    name: "SeekScreen"
    when: windowShown
    width: 960
    height: 1696

    property var sentMessages: []

    SeekScreen {
        id: seek
        width: 960
        height: 1696
        backendSender: function(message) { testCase.sentMessages.push(message) }
        navigateTo: function() {}
    }

    function init() {
        sentMessages = []
        seek.pendingAction = ""
        seek.formError = ""
        seek.waiting = false
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
        pager.moveTo(0)
        pager.pageDown()
        fuzzyCompare(pager.contentY, challenge.y, 1)
        fuzzyCompare(challenge.mapToItem(pager, 0, 0).y, 0, 1)
        compare(pager.currentPage, 2)
        compare(pager.pageCount, 2)
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
        seek.submitChallenge()
        compare(sentMessages.length, 0)
        compare(seek.formError, "Enter the Lichess username you want to challenge.")
    }

    function test_pendingRequestBlocksDuplicateSubmissionsAndRecovers() {
        seek.submitSeek()
        seek.submitSeek()
        compare(sentMessages.length, 1)
        compare(seek.pendingAction, "seek")
        compare(findChild(seek, "findOpponentButton").enabled, false)

        seek.handleMessage({type: "ErrorMsg", message: "Rate limited"})
        compare(seek.pendingAction, "")
        compare(seek.formError, "Rate limited")
        compare(findChild(seek, "findOpponentButton").enabled, true)
    }

    function test_openChallengeReplyClearsPendingAndShowsLinks() {
        seek.submitOpenChallenge()
        compare(seek.pendingAction, "open")
        seek.handleMessage({
            type: "OpenChallengeCreated",
            url: "https://lichess.org/open",
            url_white: "https://lichess.org/white",
            url_black: "https://lichess.org/black"
        })
        compare(seek.pendingAction, "")
        compare(seek.formError, "")
        compare(seek.openChallengeUrls.url_white, "https://lichess.org/white")
    }

    function test_computerLevelIsValidatedBeforeSending() {
        findChild(seek, "aiLevelField").text = "9"
        seek.submitComputerGame()
        compare(sentMessages.length, 0)
        compare(seek.formError, "Computer level must be a whole number from 1 to 8.")

        findChild(seek, "aiLevelField").text = "8"
        seek.submitComputerGame()
        compare(sentMessages.length, 1)
        compare(sentMessages[0].type, "ChallengeAi")
        compare(sentMessages[0].level, 8)
    }
}
