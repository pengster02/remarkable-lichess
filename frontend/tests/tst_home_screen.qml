import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    id: testCase
    name: "HomeScreen"
    when: windowShown
    visible: true
    width: 1696
    height: 2384
    property var sentMessages: []
    property var invitationResponses: []
    property int requestSequence: 0

    HomeScreen {
        id: home
        width: 1696
        height: 2384
        backendSender: function(message) { testCase.sentMessages.push(message) }
        nextRequestId: function() { return ++testCase.requestSequence }
        navigateTo: function() {}
        respondToChallenge: function(action, challengeId) {
            var request = {action: action, challengeId: challengeId}
            testCase.invitationResponses.push(request)
            home.pendingInvitation = request
        }
    }

    function init() {
        sentMessages = []
        invitationResponses = []
        home.loadedOnce = false
        home.connectivityKnown = false
        home.online = false
        home.wifiConnected = null
        home.connectionMessage = ""
        home.loadError = ""
        home.challengesError = ""
        home.actionError = ""
        home.pendingInvitation = null
        home.pendingChallenges = []
        home.ongoingGames = []
        home.ratings = []
    }

    function test_homeFailureStopsLoadingAndOffersRetry() {
        home.refresh()
        home.handleMessage({
            type: "ConnectivityState",
            online: false,
            wifi_connected: false,
            message: "Wi-Fi is disconnected"
        })
        home.handleMessage({
            type: "HomeLoadFailed",
            request_id: home.homeRequestId,
            message: "Wi-Fi is disconnected. Check your connection and retry."
        })
        compare(home.loadedOnce, true)
        compare(home.online, false)
        compare(home.wifiConnected, false)
        compare(home.connectivityLabel(), "Offline — Wi-Fi disconnected")
        verify(home.loadError.indexOf("Wi-Fi is disconnected") !== -1)
    }

    function test_challengeFailureDoesNotRelabelHomeAsOffline() {
        home.loadedOnce = true
        home.online = true
        home.handleMessage({
            type: "ChallengesLoadFailed",
            message: "Couldn't load challenges."
        })
        compare(home.loadedOnce, true)
        compare(home.loadError, "")
        compare(home.challengesError, "Couldn't load challenges.")
    }

    function test_genericActionErrorIsVisibleWithoutChangingLoadState() {
        home.loadedOnce = false
        home.handleMessage({type: "ErrorMsg", message: "Challenge expired"})
        compare(home.loadedOnce, false)
        compare(home.loadError, "")
        compare(home.challengesError, "")
        compare(home.actionError, "Challenge expired")
    }

    function test_pendingChallengeStaysVisibleWhenTheRowIsGone() {
        home.submitChallengeAction("accept", "abc123")
        home.submitChallengeAction("decline", "abc123")
        compare(invitationResponses, [{action: "accept", challengeId: "abc123"}])
        compare(home.pendingChallengeId, "abc123")
        home.handleMessage({type: "PendingChallenges", challenges: []})
        compare(home.pendingChallengeId, "abc123")
        var status = findChild(home, "pendingInvitationStatus")
        verify(status.visible)
        compare(status.text, "Accepting challenge…")
        home.pendingInvitation = null
        compare(home.pendingChallengeId, "")
        verify(!status.visible)
    }

    function test_successClearsAnEarlierConnectionError() {
        home.refresh()
        home.loadError = "offline"
        home.handleMessage({
            type: "ConnectivityState",
            online: true,
            wifi_connected: true,
            message: null
        })
        home.handleMessage({
            type: "HomeState",
            request_id: home.homeRequestId,
            ongoing_games: []
        })
        compare(home.ratings.length, 0)
        home.handleMessage({
            type: "HomeRatings",
            request_id: home.homeRequestId,
            ratings: [{speed: "rapid", rating: 1800}]
        })
        compare(home.loadedOnce, true)
        compare(home.loadError, "")
        compare(home.connectivityLabel(), "Online")
        compare(home.ratings.length, 1)
    }

    function test_darkModeDefaultsOff() {
        compare(home.darkMode, false)
    }
}
