import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "HomeScreen"
    when: windowShown
    width: 1696
    height: 2384

    HomeScreen {
        id: home
        width: 1696
        height: 2384
        backendSender: function() {}
        navigateTo: function() {}
    }

    function init() {
        home.loadedOnce = false
        home.connectivityKnown = false
        home.online = false
        home.wifiConnected = null
        home.connectionMessage = ""
        home.loadError = ""
        home.challengesError = ""
        home.ongoingGames = []
        home.ratings = []
    }

    function test_homeFailureStopsLoadingAndOffersRetry() {
        home.handleMessage({
            type: "ConnectivityState",
            online: false,
            wifi_connected: false,
            message: "Wi-Fi is disconnected"
        })
        home.handleMessage({
            type: "HomeLoadFailed",
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

    function test_genericActionErrorDoesNotChangeHomeState() {
        home.loadedOnce = false
        home.handleMessage({type: "ErrorMsg", message: "Challenge expired"})
        compare(home.loadedOnce, false)
        compare(home.loadError, "")
        compare(home.challengesError, "")
    }

    function test_successClearsAnEarlierConnectionError() {
        home.loadError = "offline"
        home.handleMessage({
            type: "ConnectivityState",
            online: true,
            wifi_connected: true,
            message: null
        })
        home.handleMessage({
            type: "HomeState",
            ongoing_games: [],
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
