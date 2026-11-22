import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import "logic.js" as Logic

// One machine: header, Hermes line, three ring gauges, 5-minute graph, bars, footer.
Rectangle {
    id: tile
    property var view: null             // a view from Logic.view()
    readonly property var v: view ? view : Logic.EMPTY_VIEW
    property bool showSparklines: true

    readonly property bool dim: !v.up
    readonly property color tempColor: Kirigami.Theme.neutralTextColor

    implicitWidth: Kirigami.Units.gridUnit * 17
    implicitHeight: body.implicitHeight + Kirigami.Units.largeSpacing * 2
    radius: Kirigami.Units.cornerRadius
    color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.045)
    border.width: 1
    border.color: v.worst >= Logic.WARN ? Logic.levelColor(Kirigami.Theme, v.worst)
                                        : Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.10)

    ColumnLayout {
        id: body
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.smallSpacing * 2
        opacity: tile.dim ? 0.6 : 1

        // header
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing * 2
            StatusDot { level: tile.v.statusLevel }
            PlasmaComponents.Label {
                text: tile.v.name
                font.weight: Font.DemiBold
                font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.1
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            PlasmaComponents.Label {
                text: tile.v.statusText
                font: Kirigami.Theme.smallFont
                opacity: 0.7
            }
        }

        // Hermes
        RowLayout {
            visible: tile.v.hermes !== null
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing * 2
            StatusDot {
                level: tile.v.hermes ? tile.v.hermes.level : Logic.UNKNOWN
                size: Kirigami.Units.gridUnit * 0.45
            }
            PlasmaComponents.Label {
                text: tile.v.hermes ? i18n("Hermes %1", tile.v.hermes.label) : ""
                font: Kirigami.Theme.smallFont
            }
            PlasmaComponents.Label {
                text: tile.v.hermes ? (tile.v.up ? tile.v.hermes.extra : tile.v.hermes.detail) : ""
                font: Kirigami.Theme.smallFont
                opacity: 0.7
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
                Layout.fillWidth: true
            }
        }

        // gauges
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: Kirigami.Units.smallSpacing
            spacing: 0
            Repeater {
                model: tile.v.gauges.length
                RingGauge {
                    Layout.fillWidth: true
                    Layout.maximumWidth: Infinity
                    label: (tile.v.gauges[index] || Logic.EMPTY_ITEM).label
                    value: (tile.v.gauges[index] || Logic.EMPTY_ITEM).value
                    min: (tile.v.gauges[index] || Logic.EMPTY_ITEM).min
                    max: (tile.v.gauges[index] || Logic.EMPTY_ITEM).max
                    level: (tile.v.gauges[index] || Logic.EMPTY_ITEM).level
                    text: (tile.v.gauges[index] || Logic.EMPTY_ITEM).text
                    sub: (tile.v.gauges[index] || Logic.EMPTY_ITEM).sub
                    dimmed: tile.dim
                }
            }
        }

        // 5-minute graph: CPU load (filled) and temperature
        ColumnLayout {
            visible: tile.showSparklines && tile.v.history.cpu.length > 1
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing / 2
            Sparkline {
                Layout.fillWidth: true
                Layout.preferredHeight: Kirigami.Units.gridUnit * 2.2
                opacity: tile.dim ? 0.4 : 1
                series: [
                    { values: tile.v.history.cpu, min: 0, max: 100, color: Kirigami.Theme.highlightColor, fill: true },
                    { values: tile.v.history.temp, min: 30, max: 100, color: tile.tempColor, fill: false }
                ]
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                Rectangle { width: Kirigami.Units.gridUnit * 0.6; height: 2; color: Kirigami.Theme.highlightColor }
                PlasmaComponents.Label { text: i18n("CPU"); font: Kirigami.Theme.smallFont; opacity: 0.7 }
                Item { width: Kirigami.Units.smallSpacing }
                Rectangle { width: Kirigami.Units.gridUnit * 0.6; height: 2; color: tile.tempColor }
                PlasmaComponents.Label { text: i18n("Temp"); font: Kirigami.Theme.smallFont; opacity: 0.7 }
                Item { Layout.fillWidth: true }
                PlasmaComponents.Label { text: i18n("last 5 min"); font: Kirigami.Theme.smallFont; opacity: 0.5 }
            }
        }

        // bars
        Repeater {
            model: tile.v.bars.length
            BarRow {
                Layout.fillWidth: true
                label: (tile.v.bars[index] || Logic.EMPTY_ITEM).label
                pct: (tile.v.bars[index] || Logic.EMPTY_ITEM).pct
                level: (tile.v.bars[index] || Logic.EMPTY_ITEM).level
                text: (tile.v.bars[index] || Logic.EMPTY_ITEM).text
                sub: (tile.v.bars[index] || Logic.EMPTY_ITEM).sub
                subLevel: (tile.v.bars[index] || Logic.EMPTY_ITEM).subLevel
                dimmed: tile.dim
            }
        }

        // footer: fan, network, power
        Flow {
            Layout.fillWidth: true
            spacing: Kirigami.Units.largeSpacing
            Repeater {
                model: tile.v.footer.length
                PlasmaComponents.Label {
                    text: (tile.v.footer[index] || Logic.EMPTY_ITEM).text
                    font: Kirigami.Theme.smallFont
                    color: (tile.v.footer[index] || Logic.EMPTY_ITEM).level === Logic.OK || tile.dim ? Kirigami.Theme.textColor
                                                                   : Logic.levelColor(Kirigami.Theme, (tile.v.footer[index] || Logic.EMPTY_ITEM).level)
                    opacity: (tile.v.footer[index] || Logic.EMPTY_ITEM).level === Logic.OK ? 0.7 : 1
                }
            }
        }
    }
}
