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
    property bool compact: false
    property string title: ""
    default property alias content: contentColumn.children
    width: parent ? parent.width : implicitWidth
    height: innerColumn.height +
        (sectionCard.compact ? theme.spacingXs : theme.spacingSmall) * 2

    Theme { id: theme; darkMode: sectionCard.darkMode }
    radius: theme.cardRadius
    color: theme.cardBackground
    border.width: 1
    border.color: theme.cardBorder

    Rectangle {
        anchors.left: parent.left
        anchors.leftMargin: theme.spacingXs / 2
        anchors.top: parent.top
        anchors.topMargin: theme.spacingXs
        anchors.bottom: parent.bottom
        anchors.bottomMargin: theme.spacingXs
        width: theme.sectionRailWidth
        radius: width / 2
        color: theme.sectionRail
    }

    Column {
        id: innerColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: (sectionCard.compact ? theme.spacingXs : theme.spacingSmall) +
            theme.sectionRailWidth
        anchors.rightMargin: sectionCard.compact ? theme.spacingXs : theme.spacingSmall
        anchors.topMargin: sectionCard.compact ? theme.spacingXs : theme.spacingSmall
        spacing: sectionCard.compact ? theme.spacingXs : theme.spacingSmall

        Text {
            visible: sectionCard.title.length > 0
            text: sectionCard.title
            font.pixelSize: theme.fontLabel
            font.bold: true
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 1.5
            color: theme.cardTitleText
        }

        Column {
            id: contentColumn
            width: parent.width
            spacing: sectionCard.compact ? theme.spacingXs : theme.spacingSmall
        }
    }
}
