import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    id: testCase
    name: "SettingsScreen"
    when: windowShown
    width: 960
    height: 1696
    property var sentMessages: []

    Theme {
        id: theme
    }

    SettingsScreen {
        id: settings
        width: 960
        height: 1696
        backendSender: function(message) { testCase.sentMessages.push(message) }
        navigateTo: function() {}
    }

    function init() {
        sentMessages = []
        settings.saveError = ""
        settings.rollbackRequested = false
    }

    function test_settingsUseCompactControls() {
        var names = [
            "darkModeSetting",
            "minimalHighlightsSetting",
            "autoQueenSetting",
            "confirmMovesSetting",
            "premovesSetting",
            "liveClockSetting"
        ]
        for (var i = 0; i < names.length; ++i) {
            var row = findChild(settings, names[i])
            verify(row !== null)
            compare(row.height, theme.touchTarget)
            var button = findChild(row, "settingsToggleButton")
            verify(button !== null)
            compare(button.height, theme.touchTarget)
            compare(button.width, theme.touchTarget * 2)
            compare(button.radius, button.height / 2)
        }
    }

    function test_segmentedAppearanceControlsAreRounded() {
        var boardControl = findChild(settings, "boardThemeControl")
        var pieceControl = findChild(settings, "pieceSetControl")
        verify(boardControl !== null)
        verify(pieceControl !== null)
        compare(boardControl.radius, theme.compactControlRadius)
        compare(pieceControl.radius, theme.compactControlRadius)
        verify(boardControl.radius > 0)
    }

    function test_saveFailureIsVisibleAndReloadsPersistedState() {
        settings.handleMessage({type: "ErrorMsg", message: "Storage unavailable"})
        compare(settings.saveError, "Storage unavailable")
        compare(sentMessages.length, 1)
        compare(sentMessages[0].type, "RequestSettings")

        settings.handleMessage({type: "ErrorMsg", message: "Still unavailable"})
        compare(sentMessages.length, 1)

        settings.handleMessage({type: "SettingsState"})
        compare(settings.rollbackRequested, false)
    }

    function test_previewAndNavigationStayCompact() {
        var preview = findChild(settings, "appearanceBoardPreview")
        var backButton = findChild(settings, "settingsBackButton")
        verify(preview !== null)
        verify(backButton !== null)
        verify(preview.width <= 400)
        compare(backButton.height, theme.touchTarget)
    }

    function test_nextPageBeginsAtDisplaySection() {
        var pager = findChild(settings, "settingsFlickable")
        var display = findChild(settings, "displaySection")
        var gameplay = findChild(settings, "gameplaySection")
        verify(pager !== null)
        verify(display !== null)
        verify(gameplay !== null)
        pager.moveTo(0)
        pager.pageDown()
        fuzzyCompare(pager.contentY, display.y, 1)
        pager.pageDown()
        fuzzyCompare(pager.contentY, gameplay.y, 1)
    }
}
