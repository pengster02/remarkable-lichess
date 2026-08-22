import QtQuick 2.5

Item {
    id: refreshArea

    enum Method {
        UFast,
        Fast,
        Animate,
        Content,
        UI
    }

    property int displayMethod: EinkRefreshArea.Content
    property int platformContentMethod: -1
    readonly property bool platformEnabled: Qt.application.name !== "qmltestrunner"

    // AppLoad source has used both [..., Content, UI] and [..., UI, Content].
    // Pinning one version or importing its type directly were simpler options,
    // but runtime mapping keeps installed tablets and newer hosts compatible.
    function platformMethodFor(method, contentMethod) {
        if (contentMethod !== 3 && contentMethod !== 4) return method
        if (method === EinkRefreshArea.Content) return contentMethod
        if (method === EinkRefreshArea.UI) return contentMethod === 3 ? 4 : 3
        return method
    }

    function applyDisplayMethod() {
        if (!platformArea.item || refreshArea.platformContentMethod < 0) return
        platformArea.item.displayMethod = refreshArea.platformMethodFor(
            refreshArea.displayMethod,
            refreshArea.platformContentMethod
        )
    }

    Loader {
        id: platformArea
        anchors.fill: parent
        active: refreshArea.platformEnabled
        source: "qrc:/qt/qml/net/asivery/ApploadUtils/DisplayMethodArea.qml"
        onLoaded: {
            refreshArea.platformContentMethod = item.displayMethod
            refreshArea.applyDisplayMethod()
        }
    }

    onDisplayMethodChanged: refreshArea.applyDisplayMethod()
}
