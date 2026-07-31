import QtQuick 2.5

// Draws the module matrix the backend hands over (see lichess::oauth::qr_rows),
// one '0'/'1' character per module, one string per row.
//
// Canvas rather than a Repeater of Rectangles: a URL this long encodes to a
// ~77x77 grid, and giving nearly six thousand squares their own QML item to
// lay out and render is a real cost on this device for something that is
// painted once and never animates. Alternative: encode a PNG in the backend
// and load it as an Image -- fewer moving parts here, but it pulls an image
// encoder into the backend and makes sign-in depend on a writable scratch path.
Item {
    id: qrCode

    property var rows: []
    property int moduleCount: 0
    // 4 modules is the quiet zone the QR spec requires; scanners rely on it to
    // find the symbol's edges, so it can't be trimmed to save screen space.
    property int quietZone: 4
    property int targetSize: 460
    property color darkColor: "#000000"
    property color lightColor: "#ffffff"

    readonly property int totalModules: moduleCount > 0 ? moduleCount + quietZone * 2 : 0
    // Whole-pixel modules only. A fractional size makes the canvas anti-alias
    // every module edge, and this panel renders those blended greys as mush --
    // exactly the contrast a phone camera needs to threshold cleanly.
    readonly property int moduleSize: totalModules > 0
        ? Math.max(1, Math.floor(targetSize / totalModules))
        : 0

    implicitWidth: moduleSize * totalModules
    implicitHeight: implicitWidth
    width: implicitWidth
    height: implicitHeight
    visible: totalModules > 0

    onRowsChanged: canvas.requestPaint()
    onModuleCountChanged: canvas.requestPaint()
    onModuleSizeChanged: canvas.requestPaint()
    onDarkColorChanged: canvas.requestPaint()
    onLightColorChanged: canvas.requestPaint()

    // The rectangles onPaint fills, in item pixels. Split out from the painting
    // itself so it can be checked directly: a Canvas never paints while the
    // offscreen test runner holds every item invisible, so asserting on grabbed
    // pixels would only ever see a blank image.
    function darkSpans() {
        var spans = []
        if (moduleCount <= 0 || !rows || rows.length < moduleCount) {
            return spans
        }
        var m = moduleSize
        var offset = quietZone * m
        for (var y = 0; y < moduleCount; ++y) {
            var row = rows[y]
            if (!row) {
                continue
            }
            var x = 0
            while (x < moduleCount) {
                if (row.charAt(x) !== "1") {
                    ++x
                    continue
                }
                // Merge each horizontal run into one fill -- roughly a third of
                // the draw calls of one rect per module.
                var run = 1
                while (x + run < moduleCount && row.charAt(x + run) === "1") {
                    ++run
                }
                spans.push({x: offset + x * m, y: offset + y * m, width: run * m, height: m})
                x += run
            }
        }
        return spans
    }

    Canvas {
        id: canvas
        objectName: "qrCanvas"
        anchors.fill: parent
        // Image target and immediate strategy: the device runs this frontend on
        // an e-paper scene graph where an FBO-backed, threaded canvas isn't
        // something to count on.
        renderTarget: Canvas.Image
        renderStrategy: Canvas.Immediate

        // A Canvas drops requestPaint() while it's unavailable or hidden, and
        // shows its stale buffer when it later appears. This one starts hidden
        // (the QR arrives well after the screen is built), so without these it
        // came up as a blank white square on-device -- painted once, empty,
        // before any modules existed, and never repainted.
        onAvailableChanged: if (available) requestPaint()
        onVisibleChanged: if (visible) requestPaint()

        onPaint: {
            var ctx = getContext("2d")
            ctx.fillStyle = qrCode.lightColor
            ctx.fillRect(0, 0, width, height)
            ctx.fillStyle = qrCode.darkColor
            var spans = qrCode.darkSpans()
            for (var i = 0; i < spans.length; ++i) {
                ctx.fillRect(spans[i].x, spans[i].y, spans[i].width, spans[i].height)
            }
        }
    }
}
