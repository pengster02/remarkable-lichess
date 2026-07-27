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
    readonly property bool platformEnabled: Qt.application.name !== "qmltestrunner"

    Loader {
        id: platformArea
        anchors.fill: parent
        active: refreshArea.platformEnabled
        source: "qrc:/qt/qml/net/asivery/ApploadUtils/DisplayMethodArea.qml"
        onLoaded: item.displayMethod = refreshArea.displayMethod
    }

    onDisplayMethodChanged: {
        if (platformArea.item) platformArea.item.displayMethod = refreshArea.displayMethod
    }
}
