import QtQuick 2.5
import QtQuick.Controls 2.5 as QQC2
import net.asivery.ApploadUtils

// Overrides every unqualified `Button { ... }` in this directory app-wide
// (QML resolves a same-directory file before the imported module's type of
// the same name) -- confirmed real problem, not just a hunch: this app's own
// manifest.json sets "supportsScaling": false, so QtQuick Controls' desktop-
// DPI-sized defaults render as small, inconsistently-sized tap targets on
// this device's actual (much higher) resolution, varying only with each
// button's own text length before this. It also had zero color styling at
// all -- QtQuick Controls' bare default "Basic" style chrome, completely
// disconnected from Theme, regardless of the app's own light/dark colors.
//
// Known limitation: uses Theme's default (light) instance rather than each
// screen's own darkMode, since threading darkMode into every one of this
// app's ~36 Button call sites individually is a separate, larger change --
// buttons render with consistent theme colors now, just not yet dark-mode-
// reactive like the rest of the app.
QQC2.Button {
    id: control
    Theme { id: theme }
    // Bumped again (2026-07-21) alongside Theme's own font/spacing bump --
    // live feedback was that buttons were still too small even at fontBody
    // with spacingMedium padding. A button is a tap target first, a label
    // second, so it now reads a size class *larger* than plain body text
    // (fontLarge, not fontBody) with generous padding on every side, plus an
    // explicit minimum footprint so a short label like "X" or "OK" still gets
    // a real tap target instead of shrink-wrapping to just its own text.
    font.pixelSize: theme.fontLarge
    topPadding: theme.spacingLarge
    bottomPadding: theme.spacingLarge
    leftPadding: theme.spacingLarge + theme.spacingMedium
    rightPadding: theme.spacingLarge + theme.spacingMedium
    implicitHeight: Math.max(contentItem.implicitHeight + topPadding + bottomPadding, theme.exitButtonSize)

    background: Rectangle {
        radius: theme.cardRadius
        border.width: 1
        border.color: control.highlighted ? theme.accentBackground : theme.buttonBorder
        color: control.highlighted
            ? theme.accentBackground
            : (control.pressed ? theme.buttonPressedBackground : theme.buttonBackground)
        // A disabled nav button (e.g. GameReviewScreen's Prev/Next at either
        // end) previously looked pixel-identical to an enabled one -- on
        // e-ink, a dead tap with zero visual feedback reads as "the app
        // froze," not "that action isn't available right now." Plain
        // opacity rather than a new dedicated Theme color: this needs real
        // panel contrast verification before investing in a proper
        // researched color the way every other Theme entry already has.
        opacity: control.enabled ? 1.0 : 0.45

        // Every press/release flips buttonPressedBackground on and off --
        // two Content-quality (slow, high-fidelity) waveform updates per tap
        // otherwise, for state that's purely transient tap feedback. See
        // docs/remarkable-appload-platform-notes.md §2.
        DisplayMethodArea {
            anchors.fill: parent
            displayMethod: DisplayMethodArea.Fast
        }
    }

    contentItem: Text {
        text: control.text
        font: control.font
        color: control.highlighted ? theme.accentText : theme.text
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        opacity: control.enabled ? 1.0 : 0.45
    }
}
