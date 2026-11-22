import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents

// Machine tiles that wrap to the widget's width. Resize the widget on the
// desktop to lay them out in a column, a row or a grid.
Item {
    id: full
    property var views: []
    property string errorText: ""
    property bool loaded: false
    property bool showSparklines: true
    property bool onDesktop: true

    readonly property real tileWidth: Kirigami.Units.gridUnit * 17
    readonly property real gap: Kirigami.Units.largeSpacing

    Layout.minimumWidth: tileWidth * 0.8
    Layout.minimumHeight: Kirigami.Units.gridUnit * 6
    Layout.preferredWidth: tileWidth + gap * 2
    Layout.preferredHeight: Math.min(content.implicitHeight + gap * 2, Kirigami.Units.gridUnit * 40)

    PlasmaComponents.ScrollView {
        id: scroll
        anchors.fill: parent
        anchors.margins: full.gap
        contentWidth: availableWidth
        PlasmaComponents.ScrollBar.horizontal.policy: PlasmaComponents.ScrollBar.AlwaysOff

        ColumnLayout {
            id: content
            width: scroll.availableWidth
            spacing: full.gap

            // error banner (old data stays visible underneath, dimmed)
            RowLayout {
                visible: full.errorText.length > 0
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing * 2
                Kirigami.Icon {
                    source: "dialog-warning"
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                }
                PlasmaComponents.Label {
                    text: full.errorText
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                    color: Kirigami.Theme.negativeTextColor
                }
            }

            PlasmaComponents.Label {
                visible: !full.loaded && !full.errorText
                text: i18n("Connecting…")
                opacity: 0.7
                Layout.alignment: Qt.AlignHCenter
            }
            PlasmaComponents.Label {
                visible: full.loaded && full.views.length === 0 && !full.errorText
                text: i18n("No machines are reporting (or none match the filter).")
                wrapMode: Text.WordWrap
                opacity: 0.7
                Layout.fillWidth: true
            }

            Flow {
                id: flow
                Layout.fillWidth: true
                spacing: full.gap
                opacity: full.errorText ? 0.5 : 1

                // Stretch tiles so each row fills the width.
                readonly property int perRow: Math.max(1, Math.floor((width + spacing) / (full.tileWidth + spacing)))
                readonly property real cellWidth: Math.floor((width - spacing * (perRow - 1)) / perRow)

                Repeater {
                    model: full.views.length
                    MachineTile {
                        view: full.views[index] || null
                        width: flow.cellWidth
                        showSparklines: full.showSparklines
                    }
                }
            }
        }
    }
}
