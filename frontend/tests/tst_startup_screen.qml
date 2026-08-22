import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "StartupScreen"
    when: windowShown
    width: 960
    height: 1696

    StartupScreen {
        id: startup
        width: 960
        height: 1696
    }

    function test_explainsSavedSignInCheckWithoutRequestingAToken() {
        var title = findChild(startup, "startupTitle")
        var status = findChild(startup, "startupStatus")
        verify(title !== null)
        verify(status !== null)
        verify(title.text.indexOf("board") !== -1)
        verify(status.text.indexOf("saved Lichess sign-in") !== -1)
        verify(status.text.toLowerCase().indexOf("token") === -1)
    }
}
