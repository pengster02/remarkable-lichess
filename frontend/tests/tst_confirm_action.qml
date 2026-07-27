import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    id: testCase
    name: "ConfirmAction"
    when: windowShown
    width: 600
    height: 500
    property int confirmationCount: 0

    ConfirmAction {
        id: action
        width: parent.width
        actionText: "Berserk (halve clock)"
        confirmText: "Confirm Berserk"
        cancelText: "Cancel Berserk"
        busyText: "Berserk requested"
        onConfirmed: testCase.confirmationCount += 1
    }

    function init() {
        confirmationCount = 0
        action.busy = false
        action.reset()
        action.visible = true
        wait(0)
    }

    function test_confirm() {
        var primary = findChild(action, "confirmActionPrimary")
        compare(primary.text, "Berserk (halve clock)")

        primary.clicked()
        wait(0)
        verify(action.armed)
        compare(primary.text, "Confirm Berserk")

        primary.clicked()
        wait(0)
        compare(confirmationCount, 1)
        compare(action.armed, false)
    }

    function test_cancel() {
        var primary = findChild(action, "confirmActionPrimary")
        var cancel = findChild(action, "confirmActionCancel")

        primary.clicked()
        compare(action.armed, true)
        cancel.clicked()
        wait(0)
        compare(action.armed, false)
        compare(confirmationCount, 0)
    }

    function test_busy() {
        action.busy = true
        var primary = findChild(action, "confirmActionPrimary")
        compare(primary.text, "Berserk requested")
        compare(primary.enabled, false)
    }
}
