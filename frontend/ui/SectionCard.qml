import QtQuick 2.5

// Shared bordered/tinted grouping container -- pulled out once GameHistoryScreen's
// per-row card style (border + tint, same Theme colors as everywhere else in this
// app) turned out to be exactly the visual grouping Home/Settings were missing.
// Every screen was previously just a flat, unlabeled Column of Text/Button with
// no section structure at all -- confirmed genuinely barren, not just plainly
// styled, once Home had three separate lists (ratings/games/challenges) stacked
// with nothing to tell them apart.
Rectangle {
    id: sectionCard
    property bool darkMode: false
    property string title: ""
    default property alias content: contentColumn.children
    width: parent ? parent.width : implicitWidth
    height: innerColumn.height + 24

    Theme { id: theme; darkMode: sectionCard.darkMode }
    radius: theme.cardRadius
    color: theme.cardBackground
    border.width: 1
    border.color: theme.cardBorder

    Column {
        id: innerColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: theme.spacingSmall
        spacing: theme.spacingSmall

        Text {
            visible: sectionCard.title.length > 0
            text: sectionCard.title
            font.pixelSize: theme.fontLabel
            font.bold: true
            color: theme.cardTitleText
        }

        Column {
            id: contentColumn
            width: parent.width
            spacing: theme.spacingSmall
        }
    }
}
