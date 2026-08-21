import QtQuick 2.5
import QtTest 1.2
import "../ui"

TestCase {
    name: "SettingsScreen"
    when: windowShown
    width: 960
    height: 1696

    Theme {
        id: theme
    }

    SettingsScreen {
        id: settings
        width: 960
        height: 1696
        backendSender: function() {}
        navigateTo: function() {}
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
        }
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
