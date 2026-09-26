import QtQuick
import qs.Common
import qs.Widgets

StyledRect {
    id: card

    required property var entry
    required property string title
    required property string subtitle
    required property color usageTint
    property bool compact: false
    property bool expandable: false
    property bool expanded: false

    readonly property bool hasUsage: entry && entry.percent !== null
                                     && entry.percent !== undefined
                                     && isFinite(Number(entry.percent))
    readonly property real usageFraction: hasUsage
                                          ? Math.max(0, Math.min(100, Number(entry.percent))) / 100
                                          : 0

    implicitHeight: contents.implicitHeight + 2 * Theme.spacingS
    radius: Theme.cornerRadius
    color: compact ? Theme.surfaceContainer : Theme.surfaceContainerHigh

    Column {
        id: contents
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingS
        spacing: Theme.spacingXS

        Item {
            width: parent.width
            height: Math.max(mountText.implicitHeight, percentText.implicitHeight)

            StyledText {
                id: mountText
                text: card.title
                font.pixelSize: card.compact ? Theme.fontSizeSmall : Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
                anchors.left: parent.left
                anchors.right: percentText.left
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideMiddle
                maximumLineCount: 1
            }

            StyledText {
                id: percentText
                text: card.hasUsage ? card.entry.percent + "%" : ""
                font.pixelSize: card.compact ? Theme.fontSizeSmall : Theme.fontSizeMedium
                font.weight: Font.Bold
                color: card.usageTint
                anchors.right: chevron.visible ? chevron.left : parent.right
                anchors.rightMargin: chevron.visible ? Theme.spacingS : 0
                anchors.verticalCenter: parent.verticalCenter
            }

            DankIcon {
                id: chevron
                name: "chevron_right"
                size: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: card.expandable
                rotation: card.expanded ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: 150 } }
            }
        }

        StyledText {
            text: card.subtitle
            width: parent.width
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideMiddle
            maximumLineCount: 1
        }

        StyledText {
            text: card.hasUsage ? card.entry.used + " / " + card.entry.size : "Usage unavailable"
            width: parent.width
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        Rectangle {
            width: parent.width
            height: card.compact ? 3 : 4
            radius: 2
            color: Theme.withAlpha(Theme.surfaceText, 0.1)
            visible: card.hasUsage

            Rectangle {
                width: parent.width * card.usageFraction
                height: parent.height
                radius: parent.radius
                color: card.usageTint
            }
        }
    }
}
