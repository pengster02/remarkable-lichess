import QtQuick 2.5

AppDialog {
    id: promotionDialog
    property var options: []
    property var pieceCodeFor: function() { return "" }
    signal chosen(string piece)

    title: "Choose promotion"
    dismissOnBackground: false

    Theme { id: theme; darkMode: promotionDialog.darkMode }

    Row {
        width: parent.width
        spacing: theme.spacingXs

        Repeater {
            model: promotionDialog.options

            Rectangle {
                required property string modelData
                width: (parent.width - parent.spacing *
                    Math.max(0, promotionDialog.options.length - 1)) /
                    Math.max(1, promotionDialog.options.length)
                height: Math.max(theme.touchTarget, Math.min(width, 160))
                color: promotionMouseArea.pressed ? theme.text : theme.cardBackground
                border.width: 1
                border.color: theme.text
                radius: theme.cardRadius

                Image {
                    anchors.centerIn: parent
                    width: parent.height * 0.82
                    height: width
                    fillMode: Image.PreserveAspectFit
                    smooth: true
                    source: "../assets/pieces/" +
                        promotionDialog.pieceCodeFor(modelData) + ".png"
                    sourceSize.width: width
                    sourceSize.height: height
                }

                EinkRefreshArea {
                    anchors.fill: parent
                    displayMethod: promotionMouseArea.pressed
                        ? EinkRefreshArea.Fast
                        : EinkRefreshArea.UI
                }

                MouseArea {
                    id: promotionMouseArea
                    anchors.fill: parent
                    onClicked: promotionDialog.chosen(modelData)
                }
            }
        }
    }
}
